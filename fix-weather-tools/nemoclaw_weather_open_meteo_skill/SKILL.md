---
name: weather
description: "Current weather and forecasts using Open-Meteo APIs allowed by NemoClaw's weather network policy."
metadata:
  {
    "openclaw":
      {
        "emoji": "weather",
        "requires": { "bins": ["curl"] },
      },
  }
---

# Weather

Use for current weather, rain/temperature checks, forecasts, and travel planning.

In NemoClaw sandboxes, use Open-Meteo. Do not use wttr.in; the default weather
network policy reliably allows Open-Meteo, while wttr.in may be blocked depending
on the active sandbox policy.

## Current Weather

First geocode the location:

```bash
curl -sS "https://geocoding-api.open-meteo.com/v1/search?name=Taipei&count=1&language=en&format=json"
```

Then fetch current weather with the returned latitude, longitude, and timezone:

```bash
curl -sS "https://api.open-meteo.com/v1/forecast?latitude=25.05306&longitude=121.52639&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m&timezone=Asia%2FTaipei"
```

For Taipei City, these coordinates are usually fine:

- latitude: 25.05306
- longitude: 121.52639
- timezone: Asia/Taipei

## Weather Codes

Common WMO weather codes:

- 0: clear sky
- 1, 2, 3: mainly clear, partly cloudy, overcast
- 45, 48: fog
- 51, 53, 55: drizzle
- 61, 63, 65: rain
- 80, 81, 82: rain showers
- 95, 96, 99: thunderstorm

## Response Style

Summarize the current conditions plainly. Include temperature, feels-like
temperature, humidity, precipitation, wind, and the observation time when present.

