# AFK bot skins

Drop a 64x64 `<bot username>.png` here (`fwb-afk-bot`, `fwb-afk-bot-2`; the
`bot.username` values) to replace that bot's generated Dotablaze look. A bot
reads its file at join, so restart its pod after a change. Start from
`crewskin export -name <username> -theme dotablaze -o <username>.png` in the
gameops repo. Keep the total under 1 MiB, the ConfigMap limit.
