-- ============================================================================
-- Проект 15 «Базилик» · Схема данных · ЛОКАЛЬНЫЙ PostgreSQL (Mac, Tailscale)
-- Версия: 17.08.2026, вечер. Заменяет M15_Supabase_setup.sql.
--
-- ЧТО ИЗМЕНИЛОСЬ ОТНОСИТЕЛЬНО ПРЕДЫДУЩЕЙ ВЕРСИИ (решение Dennis 17.08):
--   1. Supabase убран целиком. Хранилище — тот же локальный Postgres, что в M14
--      (YOUR_LOCAL_HOST:5432 по Tailscale, launchd de.nordwaren.postgres).
--   2. Векторный слой уехал в ЛОКАЛЬНЫЙ Qdrant (M14: ~/nordwaren-qdrant,
--      launchd de.nordwaren.qdrant, KeepAlive). Поэтому здесь больше НЕТ
--      расширения vector, колонки embedding, HNSW-индекса и RPC match_kb_chunks.
--      kb_chunks остаётся источником истины по ТЕКСТУ и состоянию индексации.
--   3. chat_id bigint → channel + user_ref (text). Причина: у Telegram это число,
--      у WhatsApp — строка wa_id (напр. 49XXXXXXXXXX). Вход двухканальный,
--      поэтому ключ пользователя обязан быть канал-агностичным.
--
-- КАК ЗАПУСКАТЬ (изоляция от базы Nordwaren — обязательна):
--   createdb -h YOUR_LOCAL_HOST -U <user> basilik
--   psql -h YOUR_LOCAL_HOST -U <user> -d basilik -f M15_Postgres_setup.sql
-- Отдельная БД, а не схема: чтобы данные M14 и M15 физически не пересекались
-- и чтобы выгрузка для сдачи не могла зацепить [PII] клиентов Nordwaren.
-- ============================================================================

-- gen_random_uuid() входит в ядро начиная с PostgreSQL 13.
-- Строка ниже — страховка для более старой версии, на PG13+ она безвредна.
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. Конфигурация ресторана (правила из политики кейса + допущения по залу)
-- ----------------------------------------------------------------------------
create table if not exists restaurant_config (
  key   text primary key,
  value text not null,
  note  text
);

insert into restaurant_config (key, value, note) values
  ('opening_time',        '12:00', 'политика: ежедневно с 12:00'),
  ('closing_time',        '23:00', 'политика: до 23:00'),
  ('kitchen_close',       '22:00', 'политика: кухня закрывается за час до зала'),
  ('last_seating',        '21:30', 'ДОПУЩЕНИЕ: последняя посадка'),
  ('min_lead_hours',      '2',     'политика: бронь минимум за 2 часа'),
  ('free_cancel_hours',   '3',     'политика: бесплатная отмена/перенос за 3 часа'),
  ('hold_minutes',        '15',    'политика: стол держится 15 минут'),
  ('prepay_party_size',   '8',     'политика: группы 8+ — предоплата'),
  ('prepay_per_person',   '15',    'политика: 15 € с человека'),
  ('banquet_party_size',  '15',    'политика: 15+ — банкет, эскалация администратору'),
  ('banquet_lead_days',   '3',     'политика: банкеты минимум за 3 дня'),
  ('banquet_prepay_pct',  '30',    'политика: предоплата 30% за 2 дня'),
  ('tables_count',        '12',    'ДОПУЩЕНИЕ: столов в зале (для проверки вместимости)'),
  ('slot_minutes',        '90',    'ДОПУЩЕНИЕ: длительность посадки'),
  ('booking_horizon_days','60',    'ДОПУЩЕНИЕ: горизонт бронирования')
on conflict (key) do update set value = excluded.value, note = excluded.note;

-- Идентификатор чата администратора живёт в конфигурации, а НЕ в переменных окружения
-- и не в выгрузке графа: личный идентификатор не должен уезжать в учебную сдачу.
-- Значение подставляет Dennis одной командой (см. M15_Кому-слать-эскалации.md).
insert into restaurant_config (key, value, note) values
  ('operator_chat_id', 'ЗАПОЛНИТЬ', 'chat_id администратора в Telegram для эскалаций и сводок')
on conflict (key) do nothing;


-- ----------------------------------------------------------------------------
-- 2. Меню — источник истины (данные из Basilik_Menu.pdf, август 2026)
--    Аллергены/следы — строго по карточкам. allergen_uncertain — стейк Рибай.
-- ----------------------------------------------------------------------------
create table if not exists menu_items (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null unique,
  category           text not null check (category in
                     ('Закуски','Супы','Паста и ризотто','Горячее','Пицца',
                      'Десерты','Напитки','Детское меню')),
  price_eur          numeric(6,2) not null,
  weight             text,
  composition        text,
  allergens          text[] not null default '{}',
  traces             text[] not null default '{}',
  allergen_uncertain boolean not null default false,
  -- СТОП-ЛИСТ (решение Dennis, 18.08): блюдо есть в меню, но сегодня закончилось.
  -- Признак ДИНАМИЧЕСКИЙ и живёт только здесь: в векторный индекс Qdrant он не идёт,
  -- иначе каждое «закончилось» требовало бы переиндексации базы знаний.
  -- Агент А2 читает его живьём из этой таблицы (узел 8b2) на каждом запросе.
  available          boolean not null default true,
  vegetarian         boolean,
  vegan              boolean,
  kcal               integer,
  notes              text
);

insert into menu_items
  (name, category, price_eur, weight, composition, allergens, traces,
   allergen_uncertain, vegetarian, vegan, kcal, notes) values
('Брускетта с томатами и базиликом','Закуски',9,'150 г',
 'чиабатта, томаты черри, базилик, чеснок, оливковое масло',
 '{глютен}','{}',false,true,true,220,'веганское — без сыра'),
('Карпаччо из говядины','Закуски',16,'120 г',
 'тонко нарезанная говядина, руккола, пармезан, лимон, оливковое масло',
 '{молоко}','{}',false,false,false,240,null),
('Ассорти сыров и вяленого мяса','Закуски',22,'250 г',
 '3 вида сыра, прошутто, салями, орехи, мёд, крекеры',
 '{молоко,глютен,орехи}','{}',false,false,false,620,null),
('Капрезе','Закуски',12,'200 г',
 'моцарелла буффало, томаты, базилик, оливковое масло',
 '{молоко}','{}',false,true,false,280,null),
('Крем-суп из тыквы','Супы',25,'300 г',
 'тыква, кокосовые сливки, имбирь, лук, чеснок, специи, тыквенные семечки',
 '{}','{орехи}',false,true,true,210,'следы орехов'),
('Минестроне','Супы',14,'320 г',
 'овощной суп с пастой, фасолью, томатами, сельдереем',
 '{глютен,сельдерей}','{}',false,true,true,180,null),
('Буйабес','Супы',19,'350 г',
 'морепродукты, томаты, шафран, белое вино, чеснок',
 '{рыба,моллюски,ракообразные,сульфиты}','{}',false,false,false,290,null),
('Паста Карбонара','Паста и ризотто',30,'280 г',
 'спагетти, гуанчале (свиная щековина), яичный желток, сыр Пекорино Романо, чёрный перец',
 '{глютен,яйца,молоко}','{}',false,false,false,520,null),
('Ризотто с грибами','Паста и ризотто',32,'320 г',
 'рис Арборио, белые грибы, пармезан, белое вино, масло, лук, чеснок, трюфельное масло',
 '{молоко}','{}',false,true,false,480,null),
('Паста Болоньезе','Паста и ризотто',26,'300 г',
 'тальятелле, говяжий рагу, томаты, пармезан',
 '{глютен,молоко,сельдерей}','{}',false,false,false,560,null),
('Ньокки с горгонзолой','Паста и ризотто',24,'280 г',
 'картофельные ньокки, соус горгонзола, грецкий орех',
 '{глютен,молоко,орехи}','{}',false,true,false,510,null),
('Ризотто с морепродуктами','Паста и ризотто',34,'320 г',
 'рис Карнароли, креветки, мидии, кальмары, белое вино, петрушка',
 '{моллюски,ракообразные,сульфиты}','{}',false,false,false,470,null),
('Стейк Рибай','Горячее',65,'200 г + соус 50 г',
 'говяжий стейк, картофель гратен, сезонные овощи; прожарка rare/medium rare/medium/well done',
 '{}','{}',true,false,false,null,
 'АЛЛЕРГЕНЫ ЗАВИСЯТ ОТ СОУСА — единого списка нет, уточнять выбор соуса у гостя'),
('Оссобуко','Горячее',36,'400 г',
 'тушёная телячья голень, гремолата, ризотто миланезе',
 '{сельдерей}','{}',false,false,false,540,null),
('Филе сибаса','Горячее',29,'220 г',
 'средиземноморская рыба, томаты черри, оливки, каперсы, белое вино',
 '{рыба}','{}',false,false,false,310,null),
('Котлета из телятины по-милански','Горячее',27,'250 г',
 'панированная телячья котлета, руккола, пармезан, томаты черри',
 '{глютен,молоко,яйца}','{}',false,false,false,480,null),
('Пицца Маргарита','Пицца',14,'300 г',
 'томатный соус, моцарелла, базилик',
 '{глютен,молоко}','{}',false,true,false,null,null),
('Пицца Дьяволо','Пицца',17,'320 г',
 'острая салями, чили, моцарелла, томатный соус',
 '{глютен,молоко}','{}',false,false,false,null,null),
('Пицца Кватро Формаджи','Пицца',18,'300 г',
 'моцарелла, горгонзола, пармезан, качотта',
 '{глютен,молоко}','{}',false,true,false,null,null),
('Пицца Прошутто э Фунги','Пицца',18,'330 г',
 'ветчина, шампиньоны, моцарелла, томатный соус',
 '{глютен,молоко}','{}',false,false,false,null,null),
('Тирамису','Десерты',9,'150 г',
 'маскарпоне, кофе, савоярди, какао',
 '{глютен,молоко,яйца}','{}',false,true,false,null,null),
('Панна-котта с ягодами','Десерты',8,'130 г',
 'сливки, ваниль, ягодный соус',
 '{молоко}','{}',false,true,false,null,null),
('Шоколадный фондан','Десерты',10,'140 г',
 'шоколад с тёплым жидким центром, ванильное мороженое',
 '{глютен,молоко,яйца}','{орехи}',false,true,false,null,'следы орехов'),
('Домашний лимонад','Напитки',6,'300 мл',
 'лимон, мята, содовая','{}','{}',false,true,true,null,null),
('Просекко (бокал)','Напитки',8,'150 мл',
 'игристое вино','{сульфиты}','{}',false,true,false,null,null),
('Эспрессо','Напитки',3,'30 мл','эспрессо','{}','{}',false,true,null,null,null),
('Капучино','Напитки',4,'180 мл','эспрессо с молоком','{молоко}','{}',false,true,false,null,null),
('Детская паста с томатным соусом','Детское меню',11,'180 г',
 'паста, томатный соус, пармезан','{глютен,молоко}','{}',false,true,false,null,null),
('Детская мини-пицца Маргарита','Детское меню',13,'200 г',
 'томатный соус, моцарелла','{глютен,молоко}','{}',false,true,false,null,null),
('Куриные наггетсы','Детское меню',16,'150 г',
 'куриное филе в панировке, картофель фри','{глютен,яйца}','{}',false,false,false,null,null)
-- Повторный запуск скрипта не должен падать и не должен затирать стоп-лист,
-- выставленный администратором: обновляем только карточку, поле available не трогаем.
on conflict (name) do update set
  category = excluded.category, price_eur = excluded.price_eur, weight = excluded.weight,
  composition = excluded.composition, allergens = excluded.allergens, traces = excluded.traces,
  allergen_uncertain = excluded.allergen_uncertain, vegetarian = excluded.vegetarian,
  vegan = excluded.vegan, kcal = excluded.kcal, notes = excluded.notes;

-- ----------------------------------------------------------------------------
-- 2b. СТОП-ЛИСТ: управление наличием блюд (администратор)
--     Наличие меняется каждый день, поэтому оно НЕ входит в базу знаний Qdrant.
--     Переиндексация при этом не нужна: А2 читает menu_items живьём.
-- ----------------------------------------------------------------------------
-- Убрать блюдо из наличия (закончилось):
--   update menu_items set available = false where name = 'Филе сибаса';
-- Вернуть в наличие:
--   update menu_items set available = true  where name = 'Филе сибаса';
-- Посмотреть текущий стоп-лист:
--   select name, category from menu_items where not available order by category, name;
-- Вернуть всё меню в наличие (утренний сброс):
--   update menu_items set available = true where not available;

-- ДЕМО-ПОДГОТОВКА К ТЕСТУ E11 («а сибас ещё есть?»): раскомментируйте перед прогоном,
-- чтобы увидеть работу стоп-листа. По умолчанию всё меню в наличии.
-- update menu_items set available = false where name = 'Филе сибаса';

-- ----------------------------------------------------------------------------
-- 3. База знаний для RAG — ТЕКСТ и состояние индексации
--    Вектора здесь НЕ хранятся: они живут в коллекции Qdrant basilik_kb.
--    Postgres остаётся источником истины по тексту, Qdrant — поисковым индексом.
--    Такое разделение позволяет переиндексировать всё из одного места
--    (правило AE-29: смена модели эмбеддинга = полная переиндексация).
-- ----------------------------------------------------------------------------
create table if not exists kb_chunks (
  id            bigint generated always as identity primary key,
  content       text not null,
  metadata      jsonb not null default '{}',
  -- md5 текста: позволяет переиндексировать только изменившиеся чанки
  content_hash  text generated always as (md5(content)) stored,
  -- Поля qdrant_point_id нет намеренно (решение Dennis 18.08): штатная нода Qdrant
  -- не возвращает id созданных точек, а идемпотентность обеспечивает content_hash.
  indexed_at    timestamptz,
  indexed_model text,          -- какой моделью посчитан вектор (bge-m3)
  indexed_dim   int            -- размерность (1024) — фиксируем для контроля
);
-- Уникальность по хэшу текста делает скрипт безопасным при повторном запуске:
-- без неё второй прогон файла удвоил бы базу знаний (41 → 82 чанка) и исказил поиск.
create unique index if not exists kb_chunks_hash_uidx on kb_chunks (content_hash);
-- Не проиндексированные чанки: select * from kb_chunks where indexed_at is null;

-- Чанки меню: генерируются из источника истины menu_items (1 блюдо = 1 чанк)
insert into kb_chunks (content, metadata)
select
  name || ' — ' || category || '. Состав: ' || coalesce(composition,'—') ||
  '. Цена: ' || price_eur || ' €. Вес: ' || coalesce(weight,'—') ||
  '. Аллергены: ' || case when allergen_uncertain
       then 'ЗАВИСЯТ ОТ СОУСА — уточнять при заказе'
       when cardinality(allergens)=0 then 'нет'
       else array_to_string(allergens, ', ') end ||
  case when cardinality(traces)>0
       then '. Следы: ' || array_to_string(traces, ', ') else '' end ||
  '. Вегетарианское: ' || case vegetarian when true then 'да' when false then 'нет' else '—' end ||
  '. Веганское: ' || case vegan when true then 'да' when false then 'нет' else '—' end ||
  case when kcal is not null then '. Калорийность: ' || kcal || ' ккал' else '' end ||
  case when notes is not null then '. Примечание: ' || notes else '' end,
  jsonb_build_object('source','menu','dish_id',id,'dish',name,'category',category,
                     'vegetarian',vegetarian,'vegan',vegan)
from menu_items
on conflict (content_hash) do nothing;

-- Чанки политики: 1 раздел = 1 чанк (текст по Basilik_Policy.pdf, август 2026)
insert into kb_chunks (content, metadata) values
('Бронирование: стол можно забронировать минимум за 2 часа до визита — через мессенджер-бота, по телефону или через форму на сайте. Для банкетов от 15 человек бронь оформляется минимум за 3 дня. Бронь считается подтверждённой только после ответного сообщения бота или администратора — заявка гостя сама по себе не гарантирует столик. Для групп от 8 человек требуется предоплата 15 € с человека, которая учитывается при финальном расчёте. Стол резервируется 15 минут от заявленного времени; при опоздании более чем на 15 минут администратор связывается с гостем напрямую.',
 '{"source":"policy","section":"Бронирование"}'),
('Отмена и перенос брони: бесплатная отмена — не позднее чем за 3 часа до времени брони. При более поздней отмене предоплата для групп от 8 человек не возвращается, так как кухня и стол уже подготовлены. Перенос брони на другое время или дату без штрафа возможен при уведомлении не позднее чем за 3 часа — это приравнивается к своевременной отмене с одновременным новым бронированием.',
 '{"source":"policy","section":"Отмена и перенос"}'),
('Напоминания и подтверждение визита: за 2 часа до брони бот автоматически отправляет гостю напоминание с просьбой подтвердить визит. Если гость не отвечает на напоминание, администратор связывается с ним лично — это снижает долю неявок (no-show), которые исторически составляли до 30 % всех броней.',
 '{"source":"policy","section":"Напоминания и подтверждение"}'),
('Банкеты и большие группы: для групп от 15 человек доступны отдельное банкетное меню и закрытая зона зала — детали обсуждаются индивидуально с администратором после первичной заявки через бота. Минимальный чек и состав меню зависят от количества гостей и даты. Оплата банкета: предоплата 30 % от предварительной суммы заказа не позднее чем за 2 дня до мероприятия, остаток — в день визита любым доступным способом.',
 '{"source":"policy","section":"Банкеты"}'),
('Детское меню: доступно в любое время работы ресторана, отдельного бронирования не требует — достаточно указать количество детей при бронировании стола. При необходимости на стол ставится детский стул; лучше сообщить об этом заранее при бронировании, хотя это не строго обязательно.',
 '{"source":"policy","section":"Детское меню"}'),
('Бизнес-ланч: подаётся по будням с 12:00 до 16:00, включает суп дня, основное блюдо на выбор и напиток за фиксированную цену 28 €. На бизнес-ланч бронирование не требуется — столы в это время выделены под быстрое обслуживание в порядке живой очереди.',
 '{"source":"policy","section":"Бизнес-ланч"}'),
('Оплата: принимаются наличные, банковские карты (Visa, Mastercard, Maestro), Apple Pay и Google Pay. Разделить счёт на несколько карт можно по запросу у официанта, ограничений по числу карт нет. Чаевые не включены в счёт и остаются на усмотрение гостя — наличными или через терминал отдельной операцией.',
 '{"source":"policy","section":"Оплата"}'),
('Свой алкоголь (corkage): гости могут принести собственное вино — сервисный сбор 15 € за бутылку, включает подачу в бокалах и обслуживание. Крепкий алкоголь и пиво со своей стороны приносить нельзя.',
 '{"source":"policy","section":"Свой алкоголь"}'),
('Дресс-код: строгого дресс-кода нет — ожидается опрятный повседневный стиль (smart casual). Исключение — закрытые банкеты, где формат обсуждается индивидуально с организатором.',
 '{"source":"policy","section":"Дресс-код"}'),
('Питомцы: небольшие питомцы допускаются на летнюю террасу на поводке или в переноске. В основном зале питомцы не допускаются, за исключением собак-проводников.',
 '{"source":"policy","section":"Питомцы"}'),
('Часы работы, адрес и парковка: ресторан работает ежедневно с 12:00 до 23:00, кухня закрывается за час до закрытия зала (в 22:00). Ресторан расположен в Берлине; собственной парковки нет, рядом доступны уличная парковка и общественная стоянка.',
 '{"source":"policy","section":"Часы и парковка"}')
on conflict (content_hash) do nothing;

-- ----------------------------------------------------------------------------
-- 4. Брони
--    channel + user_ref вместо chat_id: Telegram отдаёт число, WhatsApp — строку
--    wa_id. Ключ гостя обязан быть канал-агностичным (вход двухканальный).
-- ----------------------------------------------------------------------------
create table if not exists bookings (
  id               uuid primary key default gen_random_uuid(),
  booking_ref      text unique not null,
  channel          text not null check (channel in ('whatsapp','telegram')),
  user_ref         text not null,          -- TG: chat_id как текст; WA: wa_id
  guest_name_token text,
  phone_token      text,
  party_size       int not null check (party_size between 1 and 100),
  booking_date     date not null,
  booking_time     time not null,
  children_count   int not null default 0,
  child_chair      boolean not null default false,
  status           text not null default 'pending' check (status in
                   ('pending','confirmed','reminded_24h','reminded_2h',
                    'visit_confirmed','cancelled','no_show','completed')),
  prepay_required  boolean not null default false,
  prepay_note      text,
  comment          text,
  reminded_24h_at  timestamptz,
  reminded_2h_at   timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists bookings_date_idx on bookings (booking_date, booking_time);
create index if not exists bookings_user_idx on bookings (channel, user_ref);

-- ----------------------------------------------------------------------------
-- 5. Состояние диалога (мастер брони + human takeover)
--    consent_* — консент-гейт первого контакта: ст. 13 GDPR + ст. 50 AI Act
--    (гость должен быть уведомлён, что общается с ИИ, ДО начала обработки).
-- ----------------------------------------------------------------------------
create table if not exists chat_sessions (
  channel           text not null check (channel in ('whatsapp','telegram')),
  user_ref          text not null,
  state             jsonb not null default '{}',
  language          text not null default 'ru',
  automation_paused boolean not null default false,
  consent_given     boolean not null default false,
  consent_at        timestamptz,
  consent_version   text,                  -- версия текста уведомления
  updated_at        timestamptz not null default now(),
  primary key (channel, user_ref)
);

-- ----------------------------------------------------------------------------
-- 6. Реестр PII (минимизация ст. 5(1)(c) GDPR; TOM ст. 32)
--    Хранилище локальное, доступ — только владелец роли БД.
--    Сроки хранения финализирует DPIA (День 4).
-- ----------------------------------------------------------------------------
create table if not exists pii_registry (
  id              uuid primary key default gen_random_uuid(),
  token           text unique not null,
  pii_type        text not null check (pii_type in ('name','phone','username','email')),
  value           text not null,
  channel         text,
  user_ref        text,
  created_at      timestamptz not null default now(),
  retention_until date
);
create index if not exists pii_user_idx on pii_registry (channel, user_ref);
create index if not exists pii_retention_idx on pii_registry (retention_until);

-- ----------------------------------------------------------------------------
-- 7. Эскалации (HITL). intent_actual проставляет оператор — данные для метрики
--    роутера (критерий брифа: точность роутера ≥ 85 % по escalations)
-- ----------------------------------------------------------------------------
create table if not exists escalations (
  id               uuid primary key default gen_random_uuid(),
  operation_id     uuid,
  channel          text,
  user_ref         text,
  booking_id       uuid references bookings(id),
  intent_predicted text,
  intent_actual    text,
  reason           text,
  summary          text,
  status           text not null default 'open' check (status in
                   ('open','taken','resolved','timeout')),
  operator_note    text,
  created_at       timestamptz not null default now(),
  taken_at         timestamptz,
  resolved_at      timestamptz
);
create index if not exists escalations_status_idx on escalations (status, created_at);

-- ----------------------------------------------------------------------------
-- 8. Журнал операций (каждый запрос; Langfuse-ready)
--    retrieval_* — что вернул Qdrant: нужно для отладки порогов TH/GAP
--    и для доказательства на защите, что ответ опирался на базу знаний.
-- ----------------------------------------------------------------------------
create table if not exists operation_log (
  id                  uuid primary key default gen_random_uuid(),
  trace_id            uuid not null default gen_random_uuid(),
  channel             text,
  user_ref_hash       text,          -- хэш, не сам идентификатор
  intent              text,
  agent_used          text,
  component           text,
  model               text,
  model_profile       text check (model_profile in ('LOCAL','CLOUD')),
  tokens_in           int,
  tokens_out          int,
  latency_ms          int,
  status              text check (status in ('answered','escalated','error',
                                            'unsupported_input','consent_requested')),
  -- 'unsupported_input' — гость прислал голосовое/фото/стикер: ответ дан, но модели не звали.
  -- 'consent_requested' — гостю показано уведомление ст. 13 GDPR, согласия ещё нет.
  -- Оба намеренно НЕ 'answered': W4 (Eval) считает качество только по 'answered'.
  retry_count         int not null default 0,
  validator_result    jsonb,
  retrieval_top_score numeric(5,4),  -- лучший скор из Qdrant
  retrieval_gap       numeric(5,4),  -- разрыв между 1-м и 2-м результатом
  retrieval_hits      jsonb,         -- id/section найденных чанков
  user_message_masked text,
  reply_masked        text,
  created_at          timestamptz not null default now()
);
create index if not exists oplog_created_idx on operation_log (created_at);
create index if not exists oplog_status_idx  on operation_log (status, created_at);

-- ----------------------------------------------------------------------------
-- 9. Журнал оценки качества (по брифу школы)
-- ----------------------------------------------------------------------------
create table if not exists eval_log (
  id               uuid primary key default gen_random_uuid(),
  operation_id     uuid,
  input            text,
  output           text,
  intent_predicted text,
  intent_actual    text,
  accuracy         int check (accuracy between 0 and 10),
  completeness     int check (completeness between 0 and 10),
  tone             int check (tone between 0 and 10),
  issues           text,
  judge_model      text,             -- модель судьи ≠ модель агентов (урок M13)
  evaluated_at     timestamptz not null default now()
);

-- ============================================================================
-- ПРОВЕРКА ПОСЛЕ ПРОГОНА
--   select count(*) from menu_items;                      -- ожидается 30
--   select count(*) from kb_chunks;                       -- ожидается 41
--   select count(*) from kb_chunks where indexed_at is null;  -- 41 (ещё не в Qdrant)
--   select name, allergens, traces, allergen_uncertain from menu_items
--     where allergen_uncertain or cardinality(traces) > 0;
--     -- ожидается: Рибай (uncertain), Крем-суп из тыквы, Шоколадный фондан
--
-- СЛЕДУЮЩИЙ ШАГ: создать коллекцию в Qdrant и прогнать ingestion (W5),
-- после чего kb_chunks.indexed_at заполнится у всех 41 строк.
-- ============================================================================


-- ============================================================================
-- СЕКЦИЯ «КЭШ ОДОБРЕННЫХ ОТВЕТОВ» — добавлена 20.08.2026 по ЗАДАНИЮ-24
--
-- Зачем здесь дубль: DDL кэша жил только в отдельном файле
-- M15_Кэш-одобренных-ответов.sql, и развёртывание с нуля одним этим файлом
-- давало базу без answer_cache и kb_fingerprint(), хотя узлы 5c, 5d, 5e, 15
-- и колонка cache_hit в узле 14 на них рассчитывают. Схема разъехалась
-- по двум файлам — это уже стоило нам разбирательства с красными прогонами.
--
-- Весь DDL ниже идемпотентный (create or replace / if not exists), поэтому
-- повторный запуск и запуск обоих файлов подряд безопасны.
-- Исходный файл M15_Кэш-одобренных-ответов.sql оставлен на месте:
-- он остаётся отдельной миграцией для уже развёрнутых баз.
-- ============================================================================

-- ============================================================================
-- М15 «Базилик» — кэш одобренных ответов (миграция к M15_Postgres_setup.sql)
-- Идея Dennis, 19.08.2026: ответ, который уже прошёл валидатора, не нужно
-- сочинять заново — его нужно найти и повторить.
--
-- Ключ кэша — НЕ текст гостя, а `query_norm`: нормализованная поисковая строка,
-- которую формирует роутер («в карбонаре что?» и «what's in the carbonara»
-- оба дают «Паста Карбонара состав»). Поэтому семантический поиск здесь не нужен:
-- нормализацию уже сделала модель, а мы ищем точное совпадение. Ноль ложных
-- срабатываний — в системе про аллергены это важнее, чем процент попаданий.
-- ============================================================================

-- --------------------------------------------------------------------------
-- Отпечаток базы знаний: меняется при ЛЮБОМ изменении текста чанков
-- или стоп-листа. Ответ, выданный при другом отпечатке, автоматически
-- считается протухшим — переиндексация и «сибас закончился» обнуляют кэш сами.
-- --------------------------------------------------------------------------
create or replace function kb_fingerprint() returns text
language sql stable as $$
  select md5(
    coalesce((select string_agg(content_hash, '' order by id) from kb_chunks), '') ||
    '|' ||
    coalesce((select string_agg(name, ',' order by name) from menu_items where not available), '')
  );
$$;

create table if not exists answer_cache (
  id               uuid primary key default gen_random_uuid(),
  intent           text not null,
  -- нормализованный запрос; персональных данных здесь нет по построению:
  -- маска PII стоит ДО роутера, а роутер выдаёт только тему запроса
  question_norm    text not null,
  question_hash    text generated always as (md5(lower(question_norm))) stored,
  lang             text not null default 'ru',
  answer           text not null,
  kb_fingerprint   text not null,
  judge_valid      boolean not null default true,
  judge_model      text,
  hits             int not null default 0,
  created_at       timestamptz not null default now(),
  last_used_at     timestamptz,
  -- срок хранения: кэш не архив, а ускоритель. 30 дней — та же логика,
  -- что и у реестра PII
  expires_at       timestamptz not null default now() + interval '30 days'
);

create unique index if not exists answer_cache_key
  on answer_cache (question_hash, intent, lang);
create index if not exists answer_cache_fp on answer_cache (kb_fingerprint);

comment on table answer_cache is
  'Ответы, одобренные валидатором. Кэшируются только безопасные интенты: '
  'меню, политика, рекомендации. Аллергены НЕ кэшируются намеренно.';

-- Отметка в журнале: ответ выдан из кэша (для FinOps — такой запрос стоит 0 токенов)
alter table operation_log add column if not exists cache_hit boolean not null default false;

-- --------------------------------------------------------------------------
-- ЧТО НЕ КЭШИРУЕТСЯ И ПОЧЕМУ — это вопрос защиты, а не оптимизации
--   allergen_question — вопрос здоровья. «Аллергия на орехи» и «аллергия
--     на арахис» дают разный правильный ответ; цена ошибки несопоставима
--     с выигрышем в скорости. Такие ответы всегда собираются заново.
--   new_booking / change_booking / cancel_booking / banquet_request — ответ
--     зависит от состояния: даты, занятости, размера группы.
--   complaint — всегда человек.
--   other — по определению неизвестно, что это было.
-- Кэшируются: menu_question, policy_question, recommendation.
-- --------------------------------------------------------------------------

-- Полезные запросы администратору:
--   select intent, question_norm, hits, last_used_at from answer_cache order by hits desc;
--   доля ответов из кэша: select round(100.0*count(*) filter (where cache_hit)/nullif(count(*),0),1)
--                         from operation_log where status='answered';
--   принудительно сбросить кэш: delete from answer_cache;
