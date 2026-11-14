# StockMonitor V6 UI source bundle

Contains the current iOS app/UI source tree under `App/`, every asset in `Resources/Assets.xcassets/`, `project.yml`, and a fixture-backed static K-line mockup. `App/Charts/StockDailyCandleChart.swift` renders daily OHLC candles using only SQLite-cached `DailyBar` records; opening or manually refreshing StockDetail history does not request network data.

`Mockups/StockDetail-Kline-static-mockup.png` is clearly labeled as a static mockup, not an app runtime screenshot. Its 10 daily OHLC values come unchanged from the saved `d6-eastmoney-daily-kline.raw` fixture; the quote header values come from `eastmoney-quote-sh600000.json`. Both local fixtures and the daily fixture capture metadata are included under `Mockups/fixtures/`. No OHLC values were invented.

This bundle excludes `Sources/StockMonitorCore`, tests, generated build products, and signing material. It is not a standalone buildable app; building requires the matching core source plus Apple iOS SDK/XcodeGen. No IPA is included.
