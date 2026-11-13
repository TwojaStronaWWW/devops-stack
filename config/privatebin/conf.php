;<?php declare(strict_types=1); http_response_code(403); /*
; ==============================================================================
; PrivateBin Configuration — TwojaStronaWWW Zero-Knowledge Secret Vault
; Standard: ISO 27001 Out-of-Band Credential Sharing ("Burn After Reading")
; ==============================================================================

[main]
name = "TwojaStronaWWW • Sejf Haseł (Zero-Knowledge)"
basepath = ""
discussion = false
opendiscussion = false
password = true
fileupload = false
burnafterreadingselected = true
defaultformatter = "plaintext"
syntaxhighlightingtheme = "sons-of-obsidian"
sizelimit = 1048576
template = "bootstrap-dark"
info = "Szyfrowanie end-to-end AES-256-GCM w przeglądarce (Zero-Knowledge). Serwer nie posiada klucza deszyfrującego."
notice = "Zalecenie ISO 27001: Dla haseł produkcyjnych pozostaw włączoną opcję 'Zniszcz po przeczytaniu' (Burn after reading)."
languageselection = false
languagedefault = "pl"
qrcode = true
icon = "identicon"

[expire]
default = "1day"

[expire_options]
5min = 300
10min = 600
1hour = 3600
1day = 86400
1week = 604800

[formatter_options]
plaintext = "Plain Text"
syntaxhighlighting = "Source Code"
markdown = "Markdown"

[traffic]
limit = 10
header = "CF-Connecting-IP"
exempted = "127.0.0.1"

[purge]
limit = 300
batchsize = 10

[model]
class = Filesystem

[model_options]
dir = PATH "data"
; */ ?>
