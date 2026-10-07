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
