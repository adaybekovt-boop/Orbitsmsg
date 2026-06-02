# TK Messenger / Orbits — v9.0.2

> Draft release notes. NOT yet published. Do not create the GitHub release or
> tag from this branch until explicitly approved.

## Highlights / Главное

**English**

- **In-app updates.** Settings → Diagnostics now checks GitHub Releases and
  shows whether you're on the latest version, with release notes.
- **Windows: download + install in-app.** When an update is available, Windows
  can download the installer with a progress bar, then launch it after a clear
  confirmation. The app closes so the installer can finish; your data (chats,
  contacts, profile, keys) is preserved — only program files are updated.
- **Other platforms stay graceful.** On Android, macOS, Linux and Web the panel
  links to the GitHub release page instead of offering an in-app install.
- Calm, honest status copy and error messages throughout; no fake buttons and
  no "install" affordance on platforms that can't install.

**Русский**

- **Обновления внутри приложения.** «Настройки → Диагностика» проверяет GitHub
  Releases и показывает, установлена ли последняя версия, с примечаниями к
  релизу.
- **Windows: загрузка и установка из приложения.** Если доступно обновление, на
  Windows можно скачать установщик с индикатором прогресса и запустить его
  после подтверждения. Приложение закроется, чтобы установщик завершил
  обновление; ваши данные (чаты, контакты, профиль, ключи) сохраняются —
  обновляются только файлы программы.
- **На других платформах — аккуратный запасной путь.** На Android, macOS, Linux
  и в Web панель открывает страницу релиза на GitHub вместо установки внутри
  приложения.
- Спокойные и честные тексты статусов и ошибок; никаких «ненастоящих» кнопок и
  предложения установки там, где установка невозможна.

## Safety notes / О безопасности

- The updater never overwrites the running executable directly and never writes
  into the install directory — it downloads to a private temp folder and lets
  the signed Inno Setup installer perform the update.
- Update checks are manual or run once when the Diagnostics screen opens; there
  is no network call on app startup, so launch is never slowed.

## Scope / Объём

- Auto-update Phases 1–5 (check → status UI → Windows download → Windows install
  → verification & polish). No changes to messaging, rooms, voice, or relay.

## Asset / Файл

- Windows installer asset: `orbits-windows-x64.exe`.
