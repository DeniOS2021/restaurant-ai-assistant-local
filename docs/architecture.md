# Architektur / Architecture

```mermaid
flowchart LR
  G[Gast · Telegram / WhatsApp] --> N[Normalisierung Kanal]
  N --> C{Einwilligung?}
  C -- nein --> H13[Hinweis Art. 13 DSGVO · Art. 50 KI-VO<br/>vom Code erzeugt]
  C -- ja --> V{Sprachnachricht?}
  V -- ja --> STT[whisper.cpp lokal]
  V -- nein --> PII
  STT --> PII[Maskierung personenbezogener Daten]
  PII --> INJ[Stopp-Filter Prompt-Injection · Code]
  INJ --> R[Router · Qwen3-4B + LoRA lokal]
  R --> CA{Cache freigegebener Antworten}
  CA -- Treffer --> OUT
  CA -- kein Treffer --> SW{Route}
  SW --> A1[A1 Reservierung<br/>Regeln im Code]
  SW --> A2[A2 Menü & Allergene<br/>Qdrant + Referenzkarten]
  SW --> A3[A3 Concierge]
  A1 & A2 & A3 --> VAL[Validator]
  VAL -- ok --> OUT[Antwort Text / Piper-Sprache]
  VAL -- 1 Wiederholung --> SW
  VAL -- Fehlschlag --> HUM[Mensch · Operator-Karte]:::human
  OUT --> LOG[(Postgres-Protokoll)]
  classDef human stroke-dasharray: 5 5
```

| Workflow | Aufgabe / Purpose | Trigger |
|---|---|---|
| `P15_MAIN_Basilik` | Dialog, Routing, Agenten, Validator, Eskalation / dialogue, routing, agents | Telegram, WhatsApp |
| `P15_W2_Reminders` | Erinnerung T−2 h, Schweigen → Team informieren / reminder 2 h before | Zeitplan |
| `P15_W3_Metrics` | Kennzahlen je Stunde, Dienste-Check / hourly metrics | Zeitplan |
| `P15_W4_Eval` | nächtliche Bewertung durch Modell eines anderen Herstellers / nightly LLM-as-a-judge | Zeitplan 03:00 |
| `P15_W5_Ingestion` | Postgres → bge-m3 → Qdrant | manuell |
| `P15_W6_Booking-Summary` | Tagesübersicht der Reservierungen / daily booking summary | Zeitplan 09:00 |
| `P15_W7_Watchdog` | Überwachung der lokalen Dienste / local stack watchdog | Zeitplan, Error |

Datenbank / database: `db/01_schema.sql` (Tabellen, Beispiel-Speisekarte, Regeln) und `db/02_answer_cache.sql` (Cache mit Fingerabdruck der Wissensbasis). Kommentare im SQL auf Russisch.
