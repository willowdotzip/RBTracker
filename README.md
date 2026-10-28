# This project is no longer updated and has been archived. 



native iOS app for tracking Red Bull intake, caffeine, spending, flavours, and usage patterns.

this is the swiftui version, not the older web app idea. it has login, synced entries, daily limits, themes, charts, barcode scanning, json import/export, and a bunch of small details that make it feel like it belongs on an iphone.

it is intentionally not a medical app. rbtracker tracks cans, spend, caffeine, sugar estimates, and patterns. that is it.

## why i built this

this started as a personal tracking project because i wanted a simple way to log energy drink intake without making it feel like a boring spreadsheet.

it also became a proper app-building exercise covering:

- native swiftui interface design
- account login and session storage
- appwrite database sync
- barcode scanning and lookup data
- charts and trend summaries
- import/export flows
- mobile-first ux decisions

## current features

- email/password accounts
- synced intake logs through appwrite
- refresh on open, pull to refresh, and refresh after saving
- add, edit, delete, and reset entries
- quick add flow for fast logging
- daily can, spend, caffeine, and stop-time limits
- native barcode scanner
- built-in barcode lookup data
- per-user barcode mappings
- charts for spend, caffeine, flavour mix, and weekly trends
- json export/import
- keychain-backed sessions
- explicit appwrite session cookie storage
- liquid glass-ish swiftui interface for newer ios versions
- sensible ui fallbacks where needed

## tech stack

- swift
- swiftui
- appwrite
- keychain storage
- ios barcode scanning
- xcode

## backend

the app uses appwrite for accounts and synced user data.

this repo does **not** include a real project id, database id, table id, api key, env file, proxy url, or anything from a private setup. the included `AppConfig.plist` is intentionally full of placeholders.

edit this before running it properly:

```text
RedBullTrackeriOS/AppConfig.plist
```

you need to fill in:

- `endpoint`
- `projectId`
- `databaseId`
- `intakeTableId`
- `barcodeTableId`

there is a `chatTableId` field because the original app shape had room for that kind of feature. this ios release does not need a secret key or server-side api key in the app. do not put one in there. seriously.

the appwrite swift auth cookie handling is annoying enough that the app grabs and stores the session cookie itself.

## appwrite data shape

### intake table

the intake table expects rows with roughly this shape:

- `userId`
- `cans`
- `flavour`
- `flavourAccent`
- `sizeMl`
- `pricePerCan`
- `dateTime`
- `notes`
- `store`
- `sugarFree`
- `caffeineMgPerCan`
- `importKey`
- `source`

### barcode table

the barcode table stores:

- `userId`
- `barcode`
- `flavour`
- `sizeMl`
- `pricePerCan`
- `sugarFree`
- optional caffeine override

row security matters. if create/read/update/delete permissions are wrong, the app will complain, and it will probably be right.

## running it locally

open:

```text
RedBullTrackeriOS.xcodeproj
```

then run the `RedBullTrackeriOS` scheme on an ios 17+ simulator or device.

command line build:

```sh
xcodebuild -project RedBullTrackeriOS.xcodeproj -scheme RedBullTrackeriOS -destination 'generic/platform=iOS Simulator' build
```

## project status

this is an early but functional ios project.

known limits:

- no excel import/export in this ios release
- sync is intentionally simple right now
- no formal security testing yet
- no formal performance optimisation yet
- barcode data may need updating over time because barcode data is messy

## future improvements

- better onboarding
- more complete barcode dataset
- optional weekly summaries
- better caffeine trend insights
- test coverage
- improved offline support
- app icon and polished screenshots
- possible testflight release

## disclaimer

red bull is someone else's brand. this is just a personal tracker app. no affiliation, endorsement, secret handshake, whatever.

## notes for future me

if the barcode data looks weird, it is because barcode data is weird.
