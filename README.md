# Parquet

A [Chapel](https://chapel-lang.org/) library for reading and writing
[Apache Parquet](https://parquet.apache.org/) files. It wraps the Apache Arrow
C++ Parquet implementation and exposes a Chapel-friendly API that works with
both local and distributed (Block-distributed) arrays.

## Features

- Read and write Parquet columns by name
- Multi-column table writes via `writeTable`
- Distributed array I/O with automatic per-locale file partitioning
- Supported Chapel types: `int(32)`, `int(64)`, `uint(32)`, `uint(64)`,
  `real`, `bool`, `string`
- Compression support: None, Snappy, Gzip, Brotli, Zstd, LZ4
- Append and truncate write modes

## Requirements

- Chapel 2.8.0 or later
- Apache Arrow and Parquet C++ libraries (19.0.1 or compatible)

The C++ prerequisite libraries must be instaled and findable by `pkg-config`. The packages are typically named `arrow` and `parquet`. On Ubuntu, you can install them with:

```bash
sudo apt-get install libarrow-dev libparquet-dev
```

On MacOS, you can install them with Homebrew:

```bash
brew install apache-arrow
```

See https://arrow.apache.org/install/ for more options and details.

If you do not install the libraries through a package manager (like above or with something like `spack`), you will need to set the `PKG_CONFIG_PATH` environment variable to point to the directory containing the `.pc` files for Arrow and Parquet. For example:

```bash
export PKG_CONFIG_PATH=/path/to/arrow/lib/pkgconfig:/path/to/parquet/lib/pkgconfig:$PKG_CONFIG_PATH
```

This will allow `pkg-config` (and by extension, `mason`) to find the libraries and their headers.

## Installation

Add Parquet as a Mason dependency:

```bash
mason add Parquet@0.2.0
```

## Usage

### Writing a single column

```chapel
use Parquet;

var Arr: [1..100] int = 42;

writeColumn(filename="data.parquet", colName="values", Arr=Arr);
```

### Reading a single column

```chapel
use Parquet;

var Arr: [1..100] int;

readColumn(filename="data.parquet", colName="values", Arr=Arr);
```

### Writing a multi-column table

```chapel
use Parquet;

var col1: [1..10] int = 1;
var col2: [1..10] real = 3.14;
var col3: [1..10] bool = true;

writeTable("table.parquet",
           colNames=("col1", "col2", "col3"),
           col1, col2, col3);
```

### Writing distributed arrays

```chapel
use Parquet;
import BlockDist.blockDist;

var A = blockDist.createArray(1..1000, int);
A = 7;

write1DDistArrayParquet("distributed.parquet", "values",
                        CompressionType.SNAPPY, TRUNCATE, A);
```

## Running Tests

```bash
mason test
```

## Authors

- Engin Kayraklioglu
- Shreyas Khandekar
- Ben Harshbarger

## License

See [Mason.toml](Mason.toml).
