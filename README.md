# AI Stickers

Мысли из Telegram становятся стикерами на экране Mac.

Пишешь боту текстом или голосом, а приложение на маке делает так:

1. забирает сообщение из Telegram (long polling, без своего сервера: пока мак спит, Telegram хранит сообщения до 24 ч);
2. голосовое распознаёт локально (`ffmpeg` + `whisper-cli`);
3. сжимает мысль в стикер через `claude -p` (Haiku, по твоей подписке, без API-ключа): заголовок, короткая сводка, задачи;
4. показывает жёлтый стикер у левого края экрана. Стикер можно перетащить куда угодно, клик раскрывает и сворачивает его, 🗑 удаляет.

## Установка

Нужно: macOS 14+, `brew install ffmpeg whisper-cpp`, модель whisper (`ggml-small.bin`), установленный и залогиненный `claude`.

1. Создай бота у [@BotFather](https://t.me/BotFather) и скопируй токен.
2. Создай `~/.config/ai-stickers.env`:

   ```
   TELEGRAM_BOT_TOKEN=123456:ABC...
   # TELEGRAM_USER_ID появится после первого сообщения боту
   # необязательно, ниже значения по умолчанию:
   # WHISPER_MODEL=~/.cache/hyperframes/whisper/models/ggml-small.bin
   # FFMPEG=/opt/homebrew/bin/ffmpeg
   # WHISPER_CLI=/opt/homebrew/bin/whisper-cli
   # CLAUDE_BIN=~/.local/bin/claude
   ```

3. Запусти приложение:

   ```bash
   swift build -c release && .build/release/AiStickers
   ```

4. Напиши боту что угодно. Он ответит твоим Telegram ID: допиши `TELEGRAM_USER_ID=...` в конфиг и перезапусти приложение. Сообщения от других людей бот игнорирует.

Стикеры хранятся в `~/Library/Application Support/AiStickers/stickers.json`.

## Устройство

| Файл | Что делает |
|---|---|
| `Sources/AiStickers/main.swift` | конфиг, иконка в меню-баре, запуск |
| `Sources/AiStickers/Bot.swift` | Telegram long polling, распознавание голоса, сжатие через Claude |
| `Sources/AiStickers/Board.swift` | хранилище стикеров и плавающие окна |

Если Claude не ответил, мысль всё равно сохранится: стикером станет сырой текст.
