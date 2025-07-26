# vector.zig
Core vector search algorithms

### Running tests

The build.zig script will automatically download the [siftsmall](http://corpus-texmex.irisa.fr/) dataset
if it doesn't already exist (using [sift.sh](sift.sh)). To get a nicely formatted output, would recommend:

```bash
zig build test --summary all
```
