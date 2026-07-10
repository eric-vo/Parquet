// Copyright Hewlett Packard Enterprise Development LP.
use UnitTest;
use Parquet;
use TestUtil;

import Path;
import FileSystem as FS;

import BlockDist.blockDist;

config const n = 100;


proc testMultiColWriteRead(test: borrowed Test) throws {
  var Arr1, Arr2, Arr3: [1..10] int;
  Arr1 = 1;
  Arr2 = 2;
  Arr3 = 3;

  var In: [1..10] int;

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path,
                                   "testMultiColWriteRead.parquet");

    writeTable(filePath, colNames=("Arr1", "Arr2", "Arr3"),
               Arr1, Arr2, Arr3);

    readColumn(filePath, "Arr1", In);
    test.assertEqual(Arr1, In);
    readColumn(filePath, "Arr2", In);
    test.assertEqual(Arr2, In);
    readColumn(filePath, "Arr3", In);
    test.assertEqual(Arr3, In);
  }

  manage new tempDir() as temp {
    const doubleArr : [1..10] real = 42.0;
    const boolArr : [1..10] bool = true;
    const intArr : [1..10] int = 7;
    const uintArr : [1..10] uint = 8;

    const filePath = Path.joinPath(temp.path,
                                   "variousTypes.parquet");

    const names = ("DoubleArr", "BoolArr", "IntArr", "UintArr");
    writeTable(filePath, colNames=names,
                doubleArr, boolArr, intArr, uintArr);

    var doubleIn: [1..10] real;
    readColumn(filePath, "DoubleArr", doubleIn);
    test.assertEqual(doubleArr, doubleIn);

    var boolIn: [1..10] bool;
    readColumn(filePath, "BoolArr", boolIn);
    test.assertEqual(boolArr, boolIn);

    var intIn: [1..10] int;
    readColumn(filePath, "IntArr", intIn);
    test.assertEqual(intArr, intIn);

    var uintIn: [1..10] uint;
    readColumn(filePath, "UintArr", uintIn);
    test.assertEqual(uintArr, uintIn);
  }
}

// Multi-column single-file write mixing a flat pdarray column with a numeric
// SegArray (list) column, then reading both back. Exercises the SEGARRAY path
// of pqWriteOp/registerSegArrayColumn added for mixed/complex-type writes.
proc testMultiColWithSegArray(test: borrowed Test) throws {
  // flat column
  var flat = blockDist.createArray(0..#3, int);
  flat = [10, 20, 30];

  // segarray column: [[0, 1, 2], [3], [4, 5]]
  var segments = blockDist.createArray(0..#3, int);
  var values = blockDist.createArray(0..#6, int);
  segments = [0, 3, 4];
  values = [0, 1, 2, 3, 4, 5];

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path, "multiseg.parquet");

    var op = new pqWriteOp(filePath, flat.domain);
    op.registerColumn(flat, "flat");
    op.registerSegArrayColumn(segments, values, "lists");
    op.write();

    test.assertTrue(FS.isFile(filePath));
    test.assertEqual(getNumCols(filePath), 2);
    test.assertEqual(getArrType(filePath, "flat"), ArrowTypes.int64);
    test.assertEqual(getArrType(filePath, "lists"), ArrowTypes.list);
    test.assertEqual(getListData(filePath, "lists"), ArrowTypes.int64);

    // flat column round-trips
    var flatIn: [0..#3] int;
    readColumn(filePath, "flat", flatIn);
    for i in 0..#3 do test.assertEqual(flatIn[i], flat[i]);

    // list column structure
    var segSizes: [0..#3] int;
    const total = getListColSize(filePath, "lists", segSizes);
    test.assertEqual(total, 6);
    test.assertEqual(segSizes[0], 3);
    test.assertEqual(segSizes[1], 1);
    test.assertEqual(segSizes[2], 2);

    // list column values round-trip
    var vals: [0..#6] int;
    var rowsPerFile = [3];
    var rSeg: [0..#3] int;
    var rOff: [0..#3] int;
    readListFilesByName(vals, rowsPerFile, rSeg, rOff, [filePath], [6],
                        "lists", ArrowTypes.int64);
    for i in 0..#6 do test.assertEqual(vals[i], values[i]);
  }
}

// Numeric SegArray column containing empty lists, mixed with a flat column, in
// a single multi-column file: [[], [0, 1], [], [3, 4, 5, 6], []]
proc testMultiColSegArrayEmptySegments(test: borrowed Test) throws {
  var flat = blockDist.createArray(0..#5, real);
  flat = [1.0, 2.0, 3.0, 4.0, 5.0];

  var segments = blockDist.createArray(0..#5, int);
  var values = blockDist.createArray(0..#6, int);
  segments = [0, 0, 2, 2, 6];
  values = [0, 1, 3, 4, 5, 6];

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path, "multiseg_empty.parquet");

    var op = new pqWriteOp(filePath, flat.domain);
    op.registerSegArrayColumn(segments, values, "lists");
    op.registerColumn(flat, "flat");
    op.write();

    test.assertEqual(getNumCols(filePath), 2);
    test.assertEqual(getArrType(filePath, "lists"), ArrowTypes.list);

    var segSizes: [0..#5] int;
    const total = getListColSize(filePath, "lists", segSizes);
    test.assertEqual(total, 6);
    const expected = [0, 2, 0, 4, 0];
    for i in 0..#5 do test.assertEqual(segSizes[i], expected[i]);

    var flatIn: [0..#5] real;
    readColumn(filePath, "flat", flatIn);
    for i in 0..#5 do test.assertEqual(flatIn[i], flat[i]);
  }
}

proc testDistributedWriteRead(test: borrowed Test) throws {
  var ArrOut, ArrIn = blockDist.createArray(1..n, int);
  ArrOut = 2;

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path,
                                   "testDistributedWriteRead.parquet");

    write1DDistArrayParquet(filePath, "Arr", CompressionType.NONE, TRUNCATE,
                            ArrOut);

    test.assertTrue(FS.isFile(filePath));

    readColumn(filename=filePath, colName="Arr", Arr=ArrIn);

    test.assertEqual(ArrOut, ArrIn);
  }
}

proc testWriteRead(test: borrowed Test) throws {
  param val = 3;

  var ArrOut, ArrIn: [1..n] int;
  ArrOut = val;

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path,
                                   "testWriteRead.parquet");

    writeColumn(filename=filePath, colName="Arr", Arr=ArrOut);

    test.assertEqual(getNumCols(filePath), 1);
    test.assertEqual(getAllTypes(filePath)[0], ARROWINT64);

    readColumn(filename=filePath, colName="Arr", Arr=ArrIn);

    test.assertEqual(+ reduce ArrIn, val*n);
  }
}

proc testNumCols(test: borrowed Test) throws {
  const filename = "test/resources/multi-col.parquet";

  test.assertTrue(getNumCols(filename) == 3);
}

proc testTypes(test: borrowed Test) throws {
  const filename = "test/resources/multi-col.parquet";

  const types = getAllTypes(filename);

  test.assertEqual(types[0], ARROWINT64);
  test.assertEqual(types[1], ARROWBOOLEAN);
  test.assertEqual(types[2], ARROWINT64);
}

proc testReadColumn(test: borrowed Test) throws {
  const filename = "test/resources/multi-col.parquet";

}


UnitTest.main();
