# vector.zig
Core vector search algorithms

### iMessage example

Includes a usage example ([examples/imessage.zig](examples/imessage.zig)) which will embed all of your
iMessages locally (using on-device embedding models provided by macOS), and let you search them semantically.

Currently, it's only using exhaustive search, so performance isn't great. Lots of work to be done here.

To run the example,

```bash
zig build -Dexample=imessage -Doptimize=ReleaseFast && ./zig-out/bin/imessage
```

### Running tests

The build.zig script will automatically download the [siftsmall](http://corpus-texmex.irisa.fr/) dataset
if it doesn't already exist (using [sift.sh](sift.sh)). To get a nicely formatted output, would recommend:

```bash
zig build test --summary all
```
