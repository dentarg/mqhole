# mqhole demo

This orphan branch contains the static GitHub Pages site and terminal recording
for mqhole. The player is vendored so the page has no runtime CDN dependency.

## Files

- `index.html` and `styles.css` define the page.
- `demo.cast` is an asciicast v2 terminal recording.
- `assets/` contains asciinema-player 3.17.0 and its Apache 2.0 license.

Serve the directory locally to preview it:

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000>.

## Record

Build mqhole in a source checkout, install asciinema, and provide a CloudAMQP
team API key:

```sh
MQHOLE_BIN=/path/to/mqhole/bin/mqhole \
CLOUDAMQP_API_KEY=... \
./record-demo.sh
```

The recording script performs a real encrypted round trip and replaces
`demo.cast` only after asciinema starts successfully.
