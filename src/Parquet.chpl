// Copyright Hewlett Packard Enterprise Development LP.
module Parquet {
  use CTypes;
  use BlockDist;

  enum CompressionType {
    NONE=0,
    SNAPPY=1,
    GZIP=2,
    BROTLI=3,
    ZSTD=4,
    LZ4=5
  };



  import Reflection.{getModuleName as getM,
                     getRoutineName as getR,
                     getLineNumber as getL};

  import List.list;
  import IO.format;
  import FileSystem as FS;
  import Path;

  extern const ARROWINT64: c_int;
  extern const ARROWINT32: c_int;
  extern const ARROWUINT64: c_int;
  extern const ARROWUINT32: c_int;
  extern const ARROWBOOLEAN: c_int;
  extern const ARROWFLOAT: c_int;
  extern const ARROWSTRING: c_int;
  extern const ARROWDOUBLE: c_int;
  extern const ARROWLIST: c_int;
  extern const ARROWDECIMAL: c_int;
  extern const ARROWERROR: c_int;

  class FileWriter {
    var _wrapper : c_ptr(void);

    proc AppendRowGroup() {
      extern proc c_appendRowGroup(wrapper): c_ptr(void);

      return new RowGroupWriter(c_appendRowGroup(_wrapper));
    }

    proc close() {
      extern proc closeFileWriter(wrapper, errMsg): c_int;
      manage new parquetCall(getL(), getR(), getM()) as call {
        call.retVal = closeFileWriter(_wrapper, call.errMsg);
      }
    }
  }

  class RowGroupWriter {
    var _ptr : c_ptr(void);

    proc NextColumn() {
      extern proc c_nextColumn(ptr): c_ptr(void);

      return new ColumnWriter(c_nextColumn(_ptr));
    }
  }

  class ColumnWriter {
    var _ptr : c_ptr(void);

    proc WriteBatch(values, defLevels, repLevels, numValues) {
      extern proc c_writeBatch(ptr, values, defLevels, repLevels, numValues): c_int;

      c_writeBatch(_ptr, values, defLevels, repLevels, numValues);
    }

    proc WriteString(len, cstr, defLevels, repLevels) {
      extern proc c_writeBatchString(ptr, len, cstr, defLevels, repLevels, numValues): c_int;

      c_writeBatchString(_ptr, len, cstr, defLevels, repLevels, 1);
    }
  }

  private config const defaultBatchSize = 8192;
  config const ROWGROUPS = 512*1024*1024 / numBytes(int); // 512 mb of int64

  const TRUNCATE: int = 0;
  const APPEND: int = 1;

  class ParquetError: Error {
    proc init(msg: string) {
      super.init(msg);
    }
  }

  enum ArrowTypes { int64, int32, uint64, uint32,
                    stringArr, timestamp, boolean,
                    double, float, list, decimal,
                    notimplemented };

  proc chplTypeToCType(type t) {
    select t {
      when int(64) do return ARROWINT64;
      when int(32) do return ARROWINT32;
      when uint(64) do return ARROWUINT64;
      when uint(32) do return ARROWUINT32;
      when real do return ARROWDOUBLE;
      when bool do return ARROWBOOLEAN;
      when string do return ARROWSTRING;
      otherwise do compilerError("Unsupported Chapel type: ", t:string);
    }
  }

  record parquetCall: contextManager {
    var _errMsg: c_ptr(uint(8));
    var retVal: int;

    var err: owned Error?;

    var lineNo: int;
    var procName: string;
    var modName: string;

    proc init(lineNo, procName, modName) {
      this.lineNo = lineNo;
      this.procName = procName;
      this.modName = modName;
    }

    proc deinit() {
      // TODO errMsg is allocated through strdup in C++ code. As such, it
      // doesn't use Chapel's allocators. So, we can't really adopt the buffer
      // into a Chapel string for it causes segfaults when trying to free that
      // buffer through Chapel's allocators.
      extern proc c_free_string(ptr);
      c_free_string(_errMsg);

      // TODO this should be a thrown error in exitContext.
      // https://github.com/chapel-lang/chapel/issues/27764
      if err {
        halt(try! "Unhandled error in extern call %s.%s (%i): %s".format(
                       modName, procName, lineNo, err!.message()));
      }
    }

    proc ref errMsg do return c_ptrTo(_errMsg);

    proc ref enterContext() ref {
      return this;
    }

    proc ref exitContext(in err: owned Error?) {
      if retVal < 0 {
        var chplMsg;
        try! chplMsg = string.createCopyingBuffer(this._errMsg);
        this.err = new ParquetError(chplMsg);
      }
    }
  }

  inline proc readFilesByName(ref A: [] ?t, filenames: [] string, sizes: [] int,
      dsetname: string, ty, byteLength=-1,
      hasNonFloatNulls=false) throws {
    var dummy = [false];
    readFilesByName(A, dummy, filenames, sizes, dsetname, ty, byteLength,
        hasNonFloatNulls, hasWhereNull=false);
  }

  /*
     whereNull will be populated by the CPP interface, where `true` would mean a
     0 (null) having been read.
     */
  proc readFilesByName(ref A: [] ?t, ref whereNull: [] bool,
                       filenames: [] string, sizes: [] int, dsetname: string,
                       ty, batchSize=defaultBatchSize, byteLength=-1,
                       hasNonFloatNulls=false, param hasWhereNull=true) throws {
    extern proc c_readColumnByName(filename, arr_chpl, where_null_chpl, colNum,
                                   numElems, startIdx, batchSize, byteLength,
                                   hasNonFloatNulls, errMsg): int;

    var subdoms = getSubdomains(sizes);
    var fileOffsets = (+ scan sizes) - sizes;

    coforall loc in A.targetLocales() with (ref A) do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      var locOffsets = fileOffsets;

      forall (off, filedom, filename) in zip(locOffsets, locFiledoms,
                                             locFiles) {
        for locdom in A.localSubdomains() {
          const intersection = domain_intersection(locdom, filedom);
          if intersection.size > 0 {
            var whereNullPtr = if hasWhereNull
                                 then c_ptrTo(whereNull[intersection.low])
                                 else nil;

            manage new parquetCall(getL(), getR(), getM()) as call {
              call.retVal = c_readColumnByName(filename.localize().c_str(),
                                               c_ptrTo(A[intersection.low]),
                                               whereNullPtr,
                                               dsetname.localize().c_str(),
                                               intersection.size,
                                               intersection.low - off,
                                               batchSize,
                                               byteLength,
                                               hasNonFloatNulls,
                                               call.errMsg);
            }
          }
        }
      }
    }
  }

  proc readStrFilesByName(ref A: [] ?t, filenames: [] string, sizes: [] int,
                          dsetname: string, batchSize=defaultBatchSize) throws {
      extern proc c_readStrColumnByName(filename, arr_chpl, colname, numElems,
                                        batchSize, errMsg): int;

    var subdoms = getSubdomains(sizes);

    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;

      forall (filedom, filename) in zip(locFiledoms, locFiles) {
        for locdom in A.localSubdomains() {
          const intersection = domain_intersection(locdom, filedom);

          if intersection.size > 0 {
            var col: [filedom] t;

            manage new parquetCall(getL(), getR(), getM()) as call {
              call.retVal = c_readStrColumnByName(filename.localize().c_str(),
                                                  c_ptrTo(col),
                                                  dsetname.localize().c_str(),
                                                  filedom.size,
                                                  batchSize,
                                                  call.errMsg);
            }

            A[filedom] = col;
          }
        }
      }
    }
  }

  proc readListFilesByName(A: [] ?t, rows_per_file: [] int, seg_sizes: [] int,
                           offsets: [] int, filenames: [] string, sizes: [] int,
                           dsetname: string, ty) throws {
    extern proc c_readListColumnByName(filename, arr_chpl, colNum, numElems,
                                       startIdx, batchSize, errMsg): int;

    var subdoms = getSubdomains(sizes);
    var fileOffsets = (+ scan sizes) - sizes;
    var segmentOffsets = (+ scan rows_per_file) - rows_per_file;

    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      var locOffsets = fileOffsets; // value count offset

      // indicates which segment index is first for the file
      var locSegOffsets = segmentOffsets;

      forall (s, off, filedom, filename) in zip(locSegOffsets, locOffsets,
                                                locFiledoms, locFiles) {
        for locdom in A.localSubdomains() {
          const intersection = domain_intersection(locdom, filedom);

          if intersection.size > 0 {
            var col: [filedom] t;
            manage new parquetCall(getL(), getR(), getM()) as call {
              call.retVal = c_readListColumnByName(filename.localize().c_str(),
                                                   c_ptrTo(col),
                                                   dsetname.localize().c_str(),
                                                   filedom.size,
                                                   0,
                                                   defaultBatchSize,
                                                   call.errMsg);
            }
            A[filedom] = col;
          }
        }
      }
    }
  }

  proc calcListSizesandOffset(seg_sizes: [] ?t, filenames: [] string,
                              sizes: [] int, dsetname: string) throws {
    var subdoms = getSubdomains(sizes);

    var listSizes: [filenames.domain] int;
    var file_offset: int = 0;
    coforall loc in seg_sizes.targetLocales() with (ref listSizes) do on loc{
      var locFiles = filenames;
      var locFiledoms = subdoms;
      
      forall (i, filedom, filename) in zip(sizes.domain, locFiledoms,
                                           locFiles) {
        for locdom in seg_sizes.localSubdomains() {
          const intersection = domain_intersection(locdom, filedom);
          if intersection.size > 0 {
            var col: [filedom] t;
            listSizes[i] = getListColSize(filename, dsetname, col);
            seg_sizes[filedom] = col; // this is actually segment sizes here
          }
        }
      }
    }
    return listSizes;
  }


  proc getNullIndices(A: [] ?t, filenames: [] string, sizes: [] int,
                      dsetname: string, ty) throws {
    extern proc c_getStringColumnNullIndices(filename, colname, nulls_chpl,
                                             errMsg): int;
    var subdoms = getSubdomains(sizes);

    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;

      forall (filedom, filename) in zip(locFiledoms, locFiles) {
        for locdom in A.localSubdomains() {
          const intersection = domain_intersection(locdom, filedom);

          if intersection.size > 0 {
            var col: [filedom] t;
            var call = new parquetCall(getL(), getR(), getM());
            manage call {
              call.retVal =
                  c_getStringColumnNullIndices(filename.localize().c_str(),
                                               dsetname.localize().c_str(),
                                               c_ptrTo(col),
                                               call.errMsg);
            }
            if call.err then throw call.err;

            A[filedom] = col;
          }
        }
      }
    }
  }

  proc getStrColSize(filename: string, dsetname: string,
                     ref offsets: [] int) throws {
    extern proc c_getStringColumnNumBytes(filename, colname, offsets, numElems,
                                          startIdx, batchSize, errMsg): int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getStringColumnNumBytes(filename.localize().c_str(),
                                              dsetname.localize().c_str(),
                                              c_ptrTo(offsets),
                                              offsets.size,
                                              0,
                                              256,
                                              call.errMsg);
    }
    if call.err then throw call.err;

    return call.retVal;
  }

  proc getStrListColSize(filename: string, dsetname: string,
                         ref offsets: [] int) throws {
    extern proc c_getStringListColumnNumBytes(filename, colname, offsets,
                                              numElems, startIdx, batchSize,
                                              errMsg): int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getStringListColumnNumBytes(filename.localize().c_str(),
                                                  dsetname.localize().c_str(),
                                                  c_ptrTo(offsets),
                                                  offsets.size,
                                                  0,
                                                  256,
                                                  call.errMsg);
    }
    if call.err then throw call.err;

    return call.retVal;
  }

  proc getListColSize(filename: string, dsetname: string,
                      ref seg_sizes: [] int) throws {
    extern proc c_getListColumnSize(filename, colname, seg_sizes, numElems,
                                    startIdx, errMsg): int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getListColumnSize(filename.localize().c_str(),
                                        dsetname.localize().c_str(),
                                        c_ptrTo(seg_sizes),
                                        seg_sizes.size,
                                        0,
                                        call.errMsg);
    }
    if call.err then throw call.err;

    return call.retVal;
  }

  proc getArrSize(filename: string) throws {
    extern proc c_getNumRows(str_chpl, errMsg): int;

    var call = new parquetCall(getL(), getR(), getM());

    manage call {
      call.retVal = c_getNumRows(filename.localize().c_str(),
                                 call.errMsg);
    }
    if call.err then throw call.err;

    return call.retVal;
  }

  proc typeFromCType(ctype) throws {
    select ctype {
      when ARROWINT64   do return ArrowTypes.int64;
      when ARROWINT32   do return ArrowTypes.int32;
      when ARROWUINT32  do return ArrowTypes.uint32;
      when ARROWUINT64  do return ArrowTypes.uint64;
      when ARROWBOOLEAN do return ArrowTypes.boolean;
      when ARROWSTRING  do return ArrowTypes.stringArr;
      when ARROWDOUBLE  do return ArrowTypes.double;
      when ARROWFLOAT   do return ArrowTypes.float;
      when ARROWLIST    do return ArrowTypes.list;
      when ARROWDECIMAL do return ArrowTypes.decimal;
      otherwise do throw new ParquetError("Unrecognized Parquet data type");
    }
  }

  proc getArrType(filename: string, colname: string) throws {
    extern proc c_getType(filename, colname, errMsg): c_int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getType(filename.localize().c_str(),
                              colname.localize().c_str(),
                              call.errMsg);
    }
    if call.err then throw call.err;

    return typeFromCType(call.retVal);
  }

  proc getListData(filename: string, dsetname: string) throws {
    extern proc c_getListType(filename, dsetname, errMsg): c_int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getListType(filename.localize().c_str(),
                                  dsetname.localize().c_str(),
                                  call.errMsg);

      if call.retVal == ARROWLIST {
        throw new ParquetError("List element types cannot be list");
      }
    }
    if call.err then throw call.err;

    return typeFromCType(call.retVal);
  }

  proc writeDistArrayToParquet(A, filename, dsetname, rowGroupSize,
                               compression, mode) throws {
    extern proc c_writeColumnToParquet(filename, arr_chpl, colnum,
                                       dsetname, numelems, rowGroupSize,
                                       dtype, compression, errMsg): int;
    extern proc c_appendColumnToParquet(filename, arr_chpl,
                                        dsetname, numelems,
                                        dtype, compression,
                                        errMsg): int;
    var (prefix, extension) = getFileMetadata(filename);

    // Generate the filenames based upon the number of targetLocales.
    var filenames = generateFilenames(prefix, extension,
                                      A.targetLocales().size);
    var numElemsPerFile: [filenames.domain] int;

    //Generate a list of matching filenames to test against. 
    var matchingFilenames = getMatchingFilenames(prefix, extension);

    var filesExist = processParquetFilenames(filenames, matchingFilenames,
                                             mode);

    if mode == APPEND {
      if filesExist {
        var datasets = getDatasets(filenames[0]);
        if datasets.contains(dsetname) then
          throw new ParquetError("A column with name " + dsetname +
                                 " already exists in Parquet file");
      }
    }

    coforall (loc, idx) in zip(A.targetLocales(), filenames.domain) do on loc {
        const myFilename = filenames[idx];

        var locDom = A.localSubdomain();
        var locArr = A[locDom]; // Engin: why are we doing this??

        numElemsPerFile[idx] = locDom.size;

        var valPtr: c_ptr(void) = nil;
        if locArr.size != 0 {
          valPtr = c_ptrTo(locArr);
        }
        if mode == TRUNCATE || !filesExist {
          writeColumn(filename, dsetname, A, locDom, rowGroupSize, compression);
        } else {
          const dtype = chplTypeToCType(A.eltType);
          manage new parquetCall(getL(), getR(), getM()) as call {
            call.retVal = c_appendColumnToParquet(myFilename.localize().c_str(),
                                                  valPtr,
                                                  dsetname.localize().c_str(),
                                                  locDom.size,
                                                  dtype,
                                                  compression,
                                                  call.errMsg);
          }
        }
      }
    // Only warn when files are being overwritten in truncate mode
    return (filesExist && mode == TRUNCATE, filenames, numElemsPerFile);
  }

  proc createEmptyParquetFile(filename: string, dsetname: string, dtype: int,
                              compression: int) throws {
    extern proc c_createEmptyParquetFile(filename, dsetname, dtype,
                                         compression, errMsg): int;

    manage new parquetCall(getL(), getR(), getM()) as call {
      call.retVal = c_createEmptyParquetFile(filename.localize().c_str(),
                                             dsetname.localize().c_str(),
                                             dtype, compression,
                                             call.errMsg);
    }
  }

  proc writeStringsComponentToParquet(filename, dsetname,
                                      ref values: [] uint(8),
                                      ref offsets: [] int, rowGroupSize,
                                      compression, mode,
                                      filesExist) throws {
    extern proc c_writeStrColumnToParquet(filename, arr_chpl, offsets_chpl,
                                          dsetname, numelems, rowGroupSize,
                                          dtype, compression, errMsg): int;
    extern proc c_appendColumnToParquet(filename, arr_chpl,
                                        dsetname, numelems,
                                        dtype, compression,
                                        errMsg): int;

    var dtypeRep = ARROWSTRING;
    if mode == TRUNCATE || !filesExist {
      manage new parquetCall(getL(), getR(), getM()) as call {
        call.retVal = c_writeStrColumnToParquet(filename.localize().c_str(),
                                                c_ptrTo(values),
                                                c_ptrTo(offsets),
                                                dsetname.localize().c_str(),
                                                offsets.size-1,
                                                rowGroupSize,
                                                dtypeRep,
                                                compression,
                                                call.errMsg);
      }
    } else if mode == APPEND {
      manage new parquetCall(getL(), getR(), getM()) as call {
        call.retVal = c_appendColumnToParquet(filename.localize().c_str(),
                                              c_ptrTo(values),
                                              dsetname.localize().c_str(),
                                              offsets.size-1,
                                              dtypeRep,
                                              compression,
                                              call.errMsg);
      }
    }
  }

  proc write1DDistArrayParquet(filename: string, dsetname, compression,
                               mode, A) throws {
    return writeDistArrayToParquet(A, filename, dsetname, ROWGROUPS,
                                   compression, mode);
  }

  proc populateTagData(A, filenames: [?fD] string, sizes) throws {
    var subdoms = getSubdomains(sizes);
    var fileOffsets = (+ scan sizes) - sizes;

    coforall loc in A.targetLocales() do on loc {
      var locFiles = filenames;
      var locFiledoms = subdoms;
      var locOffsets = fileOffsets;

      try {
        forall (off, filedom, filename, tag) in zip(locOffsets, locFiledoms,
                                                    locFiles, 0..) {
          for locdom in A.localSubdomains() {
            const intersection = domain_intersection(locdom, filedom);

            if intersection.size > 0 {
              // write the tag into the entry
              A[intersection] = tag;
            }
          }
        }
      }
    }
  }

  iter datasets(filename) {
    extern proc c_getDatasetNames(filename, dsetResult, readNested,
                                  errMsg): int(32);
    var res: c_ptr(uint(8));

    manage new parquetCall(getL(), getR(), getM()) as call {
      call.retVal = c_getDatasetNames(filename.c_str(),
                                      c_ptrTo(res),
                                      false,
                                      call.errMsg);
    }
    const datasets = try! string.createAdoptingBuffer(res);

    for s in datasets.split(",") do yield s;
  }

  // TODO remove this and use the iterator everywhere, or turn this into a
  // list-returning version
  proc getDatasets(filename) throws {
    extern proc c_getDatasetNames(filename, dsetResult, readNested,
                                  errMsg): int(32);

    var res: c_ptr(uint(8));

    manage new parquetCall(getL(), getR(), getM()) as call {
      call.retVal = c_getDatasetNames(filename.c_str(),
                                      c_ptrTo(res),
                                      false,
                                      call.errMsg);
    }
    const datasets = string.createAdoptingBuffer(res);

    return new list(datasets.split(","));
  }

  proc createEmptyListParquetFile(filename: string, dsetname: string,
                                  dtype: int, compression: int) throws {
    extern proc c_createEmptyListParquetFile(filename, dsetname, dtype,
                                         compression, errMsg): int;

    manage new parquetCall(getL(), getR(), getM()) as call {
      call.retVal = c_createEmptyListParquetFile(filename.localize().c_str(),
                                                 dsetname.localize().c_str(),
                                                 dtype,
                                                 compression,
                                                 call.errMsg);
    }
  }

  /*
     Writes the local chunk of a numeric list (segarray) column for a single
     locale. `segments` gives the starting index into the values array for each
     list.
  */
  private proc writeListColumnComponent(filename: string, dsetname: string,
                                        const ref segments: [] int,
                                        const ref values: [] ?t,
                                        locDom, c_dtype, compression) throws {
    extern proc c_writeListColumnToParquet(filename, arr_chpl, offsets_chpl,
                                           dsetname, numelems, rowGroupSize,
                                           dtype, compression, errMsg): int;

    var locSegments: [0..#locDom.size+1] int;
    locSegments[0..#locDom.size] = segments[locDom];
    if locDom.high == segments.domain.high then
      locSegments[locSegments.domain.high] = values.size;
    else
      locSegments[locSegments.domain.high] = segments[locDom.high + 1];

    // Writes this locale's segments (with the given value pointer)
    // to the Parquet file.
    proc writeChunk(valPtr: c_ptr(void)) throws {
      var call = new parquetCall(getL(), getR(), getM());
      manage call {
        call.retVal = c_writeListColumnToParquet(filename.localize().c_str(),
                                                 c_ptrTo(locSegments),
                                                 valPtr,
                                                 dsetname.localize().c_str(),
                                                 locSegments.size-1,
                                                 ROWGROUPS,
                                                 c_dtype,
                                                 compression,
                                                 call.errMsg);
      }
      if call.err then throw call.err;
    }

    const valIdxRange = locSegments[0]..locSegments[locDom.size]-1;
    var localVals: [valIdxRange] t = values[valIdxRange];
    const valPtr: c_ptr(void) = if localVals.size > 0
                                  then c_ptrTo(localVals)
                                  else nil;

    writeChunk(valPtr);
  }

  /*
     Writes a numeric list (segarray) column to Parquet. `segments` is a
     distributed array where each entry is the starting index into `values` of
     the corresponding list; `values` holds the concatenated list elements.
     One file is written per target locale, matching the layout used by
     `write1DDistArrayParquet`. Returns whether existing files were overwritten.
  */
  proc writeListColumn(filename: string, colName: string,
                       const ref segments: [] int, const ref values: [] ?t,
                       compression=CompressionType.NONE) throws {
    const c_dtype = chplTypeToCType(t);
    const comp = compression: int;

    var (prefix, extension) = getFileMetadata(filename);
    var filenames = generateFilenames(prefix, extension,
                                      segments.targetLocales().size);
    var matchingFilenames = getMatchingFilenames(prefix, extension);
    var filesExist = processParquetFilenames(filenames, matchingFilenames,
                                             TRUNCATE);

    coforall (loc, idx) in zip(segments.targetLocales(), filenames.domain)
        do on loc {
      const myFilename = filenames[idx];
      const locDom = segments.localSubdomain();

      if locDom.isEmpty() || locDom.size <= 0 {
        createEmptyListParquetFile(myFilename, colName, c_dtype, comp);
      } else {
        writeListColumnComponent(myFilename, colName, segments,
                                 values, locDom, c_dtype, comp);
      }
    }

    return filesExist;
  }

  /*
     Writes the local chunk of a list-of-strings (segarray of strings) column
     for a single locale. `segments` indexes into `offsets` (one entry per
     list), `offsets` indexes into `values` (one entry per string), and
     `values` holds the raw string bytes.
  */
  private proc writeStrListColumnComponent(filename: string, dsetname: string,
                                           const ref segments: [] int,
                                           const ref offsets: [] int,
                                           const ref values: [] uint(8),
                                           locDom, dtypeRep,
                                           compression) throws {
    extern proc c_writeStrListColumnToParquet(filename, segs_chpl, offsets_chpl,
                                              arr_chpl, dsetname, numelems,
                                              rowGroupSize, dtype, compression,
                                              errMsg): int;

    // Build this locale's segment offsets with a trailing terminator so the
    // last list's length can be computed by the C writer.
    var locSegments: [0..#locDom.size+1] int;
    locSegments[0..#locDom.size] = segments[locDom];
    if locDom.high == segments.domain.high then
      locSegments[locSegments.domain.high] = offsets.size;
    else
      locSegments[locSegments.domain.high] = segments[locDom.high + 1];

    // Writes this locale's segments (with the given value/offset pointers) to
    // the Parquet file.
    proc writeChunk(offPtr: c_ptr(void), valPtr: c_ptr(void)) throws {
      var call = new parquetCall(getL(), getR(), getM());
      manage call {
        call.retVal =
            c_writeStrListColumnToParquet(filename.localize().c_str(),
                                          c_ptrTo(locSegments),
                                          offPtr,
                                          valPtr,
                                          dsetname.localize().c_str(),
                                          locSegments.size - 1,
                                          ROWGROUPS,
                                          dtypeRep,
                                          compression,
                                          call.errMsg);
      }
      if call.err then throw call.err;
    }

    // Range of string offsets owned by this locale.
    const startOffset = locSegments[0];
    const endOffset =
        if locDom.high == segments.domain.high
          then offsets.domain.high
          else segments[locDom.high + 1] - 1;
    const offsetRange = startOffset..endOffset;

    // This locale owns segments but no string bytes (all lists are empty), so
    // there are no values/offsets to send.
    if offsetRange.size <= 0 {
      writeChunk(nil, nil);
      return;
    }

    var locOffsets: [0..#offsetRange.size+1] int;
    locOffsets[0..#offsetRange.size] = offsets[offsetRange];
    locOffsets[locOffsets.domain.high] =
        if offsetRange.high == offsets.domain.high
          then values.size
          else offsets[offsetRange.high + 1];

    // Range of value bytes owned by this locale. `segments` (and thus
    // `locSegments`) index into `offsets`, and `offsets` index into `values`,
    // so the byte bounds must be read out of `offsets`, not `locSegments`.
    const startVal = offsets[offsetRange.low];
    const endVal = if offsetRange.high == offsets.domain.high
                     then values.domain.high
                     else offsets[offsetRange.high + 1] - 1;
    const valIdxRange = startVal..endVal;
    var localVals: [valIdxRange] uint(8) = values[valIdxRange];

    const offPtr: c_ptr(void) = c_ptrTo(locOffsets);
    const valPtr: c_ptr(void) = if localVals.size > 0
                                  then c_ptrTo(localVals)
                                  else nil;
    writeChunk(offPtr, valPtr);
  }

  /*
     Writes a list-of-strings (segarray of strings) column to Parquet.
     `segments` indexes into `offsets` (one entry per list), `offsets` indexes
     into `values` (one entry per string), and `values` holds the raw string
     bytes. One file is written per target locale. Returns whether existing
     files were overwritten.
  */
  proc writeStrListColumn(filename: string, colName: string,
                          const ref segments: [] int,
                          const ref offsets: [] int,
                          const ref values: [] uint(8),
                          compression=CompressionType.NONE) throws {
    const comp = compression: int;
    const dtypeRep = ARROWSTRING;

    var (prefix, extension) = getFileMetadata(filename);
    var filenames = generateFilenames(prefix, extension,
                                      segments.targetLocales().size);
    var matchingFilenames = getMatchingFilenames(prefix, extension);
    var filesExist = processParquetFilenames(filenames, matchingFilenames,
                                             TRUNCATE);

    coforall (loc, idx) in zip(segments.targetLocales(), filenames.domain)
        do on loc {
      const myFilename = filenames[idx];
      const locDom = segments.localSubdomain();

      if locDom.isEmpty() || locDom.size <= 0 {
        createEmptyListParquetFile(myFilename, colName, ARROWSTRING, comp);
      } else {
        // segment refers to segarray offsets;
        // offset refers to string byte offsets
        writeStrListColumnComponent(myFilename, colName, segments, offsets,
                                    values, locDom, dtypeRep, comp);
      }
    }
    return filesExist;
  }

  proc getNumCols(filename: string) throws {
    extern proc c_getNumCols(filename, errMsg): int(64);

    var numCols: int;
    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getNumCols(filename.c_str(), call.errMsg);
    }
    if call.err then throw call.err;
    return call.retVal;
  }

  proc getAllTypes(filename: string): [] c_int throws {
    extern proc c_getAllTypes(filename, types_out, errMsg): c_int;

    const numCols = getNumCols(filename);

    var Types: [0..#numCols] c_int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_getAllTypes(filename.c_str(),
                                  c_ptrTo(Types),
                                  call.errMsg);
    }
    if call.err then throw call.err;

    return Types;
  }

  proc writeColumn(filename, colName, const ref Arr: [],
                   const ref WriteDom: domain(?) = Arr.domain,
                   rowGroupSize=ROWGROUPS,
                   compression=CompressionType.NONE) throws {
    extern proc c_writeColumnToParquet(filename, arr_chpl, colnum,
                                       dsetname, numelems, rowGroupSize,
                                       dtype, compression, errMsg): int;

    const dtype = chplTypeToCType(Arr.eltType);

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_writeColumnToParquet(filename.localize().c_str(),
                                           arr_chpl=c_ptrToConst(Arr[WriteDom.low]),
                                           colnum=0,
                                           dsetname=colName.localize().c_str(),
                                           numelems=WriteDom.size,
                                           rowGroupSize=ROWGROUPS,
                                           dtype=dtype,
                                           compression=compression,
                                           call.errMsg);
    }
    if call.err then throw call.err;
  }

  record pqWriteLocalChunkInfo {
    var c_colName: c_ptrConst(c_char);
    var c_data: c_ptrConst(void);
    var c_type: int;
    var size: int;
  }

  record pqWriteOp {

    var filenameBase: string;
    var sharedDom: domain(?);

    // per locale store for pqWriteLocalChunkInfo
    var info = blockDist.createArray(sharedDom.targetLocales().domain,
                                     list(pqWriteLocalChunkInfo),
                                     targetLocales=sharedDom.targetLocales());

    var colCount: int;

    proc ref registerColumn(const A: [?colDom] ?eltType, colName: string) {
      // TODO check domain alignment

      coforall (loc, localInfo) in zip(sharedDom.targetLocales(), info) {
        on loc {
          const ref localSubDom = A.localSubdomain();

          var ptr = c_pointer_return_const(A[localSubDom.first]);

          localInfo.pushBack(
              new pqWriteLocalChunkInfo(colName.localize().c_str(),
                                        ptr,
                                        chplTypeToCType(eltType),
                                        localSubDom.size));
        }
      }

      colCount += 1;
    }

    proc write() {
      extern proc createFileWriter(filename, column_names,
                                   objTypes, datatypes,
                                   colnum,
                                   compression,
                                   writer,
                                   errMsg): c_int;

      coforall (loc, localInfo) in zip(sharedDom.targetLocales(), info) {
        on loc {
          assert(localInfo.size == colCount);

          const colDom = {0..#colCount};

          var c_colNames: [colDom] c_ptrConst(c_char);
          var c_datas: [colDom] c_ptrConst(void);
          var c_types: [colDom] int;
          var c_objTypes: [colDom] int = 1;
          var sizes: [colDom] int;

          for (colInfo,   c_colName,  c_data,  c_type,  size) in
           zip(localInfo, c_colNames, c_datas, c_types, sizes) {

             c_colName = colInfo.c_colName;
             c_data = colInfo.c_data;
             c_type = colInfo.c_type;
             size = colInfo.size;
          }

          const c_filename = filenameBase.localize().c_str();
          var writer = new FileWriter();
          manage new parquetCall(getL(), getR(), getM()) as call {
            call.retVal = createFileWriter(c_filename,
                                           c_ptrTo(c_colNames),
                                           c_ptrTo(c_objTypes),
                                           c_ptrTo(c_types),
                                           colCount,
                                           compression=0,
                                           c_ptrTo(writer._wrapper),
                                           call.errMsg);
          }

          var numLeft = sizes[0];

          // TODO:
          // - implement other data types
          // - implement SEGARRAY?
          for i in 0..#numLeft by ROWGROUPS {
            const batchSize = min(numLeft-i, ROWGROUPS);

            var rg_writer = writer.AppendRowGroup();
            for (data, kind) in zip(c_datas, c_types) {
              if kind == ARROWINT64 || kind == ARROWUINT64 ||
                 kind == ARROWBOOLEAN || kind == ARROWDOUBLE {
                var col_writer = rg_writer.NextColumn();
                col_writer.WriteBatch(data, nil, nil, batchSize);
              } else if kind == ARROWSTRING {
                var col_writer = rg_writer.NextColumn();
                var def_level = 1;

                var strs = data:c_ptrConst(string);
                for i in 0..#batchSize {
                  const ref str = strs[i];
                  col_writer.WriteString(str.size, str.c_str(), c_ptrTo(def_level), nil);
                }
              }
            }
          }

          writer.close();
        }
      }
    }
  }

  proc writeTable(filename, colNames, const Arrs...) {
    var op = new pqWriteOp(filename, Arrs[0].domain);

    for param i in 0..<Arrs.size do op.registerColumn(Arrs[i], colNames[i]);

    op.write();
  }

  /* This is the Chapel array-based interface */
  proc readColumn(filename, colName, ref Arr: [], ref WhereNull: [] = [0],
                  const ref ReadDom: domain(?) = Arr.domain, startIdx=0,
                  batchSize=defaultBatchSize, byteLength=-1,
                  hasNonFloatNulls=false) throws {

    var whereNullPtr = if hasNonFloatNulls then c_ptrTo(WhereNull[ReadDom.low])
                                           else nil;

    readColumn(filename=filename,
               colName=colName,
               ptr=c_ptrTo(Arr[ReadDom.low]),
               whereNullPtr=whereNullPtr,
               numElems=ReadDom.size,
               startIdx=startIdx,
               batchSize=batchSize,
               byteLength=byteLength,
               hasNonFloatNulls=hasNonFloatNulls);
  }

  /* This is the C pointer based interface */
  proc readColumn(filename, colName, ptr: c_ptr(void),
                  whereNullPtr: c_ptr(void), const numElems: int, startIdx=0,
                  batchSize=defaultBatchSize, byteLength=-1,
                  hasNonFloatNulls=false) throws {

    // TODO this should probably do dynamic type checking 
    // TODO Arr should be local

    extern proc c_readColumnByName(filename, arr_chpl, where_null_chpl,
                                    colName, numElems, startIdx, batchSize,
                                    byteLength, hasNonFloatNulls, errMsg): int;

    var call = new parquetCall(getL(), getR(), getM());
    manage call {
      call.retVal = c_readColumnByName(filename=filename.localize().c_str(),
                                       arr_chpl=ptr,
                                       where_null_chpl=whereNullPtr,
                                       colName=colName.localize().c_str(),
                                       numElems=numElems,
                                       startIdx=startIdx,
                                       batchSize=batchSize,
                                       byteLength=byteLength,
                                       hasNonFloatNulls=hasNonFloatNulls,
                                       call.errMsg);
    }
    if call.err then throw call.err;
  }

  proc toCDtype(dtype: string) throws {
    select dtype {
      when 'int64' {
        return ARROWINT64;
      } when 'uint32' {
        return ARROWUINT32;
      } when 'uint64' {
        return ARROWUINT64;
      } when 'bool' {
        return ARROWBOOLEAN;
      } when 'float64' {
        return ARROWDOUBLE;
      } when 'str' {
        return ARROWSTRING;
      } otherwise {
        throw new ParquetError("Trying to convert unrecognized dtype " +
                               "to Parquet type");
        return ARROWERROR;
      }
    }
  }

  /*
     Returns the intersection of two 1-D domains. Chapel domain slicing already
     computes the intersection for rectangular domains, so this is just a named
     wrapper around `d1[d2]`.
  */
  private proc domain_intersection(d1: domain(1), d2: domain(1)) {
    return d1[d2];
  }

  /*
     Given an array of per-file lengths, returns the contiguous index subdomain
     that each file occupies within the concatenated value space.
  */
  private proc getSubdomains(lengths: [?FD] int) {
    var subdoms: [FD] domain(1);
    var offset = 0;
    for i in FD {
      subdoms[i] = {offset..#lengths[i]};
      offset += lengths[i];
    }
    return subdoms;
  }

  private proc processParquetFilenames(filenames: [] string,
                                       matchingFilenames: [] string,
                                       mode: int) throws {
    var filesExist: bool = true;
    if mode == APPEND {
      if matchingFilenames.size == 0 {
        // Files do not exist, so we can just create the files
        filesExist = false;
      }
      else if matchingFilenames.size != filenames.size {
        throw new ParquetError("Appending to existing files must be done with "+
                               "the same number of locales. Try saving with a "+
                               "different directory or filename prefix?");
      }
    } else if mode == TRUNCATE {
      if matchingFilenames.size > 0 {
        filesExist = true;
      } else {
        filesExist = false;
      }
    } else {
      throw new ParquetError("The mode %? is invalid".format(mode));
    }
    return filesExist;
  }

  /* Copied verbatim from Arkouda. This is a general helper in Arkouda. */
  private proc getFileMetadata(filename : string) {
    const fields = filename.split(".");
    var prefix: string;
    var extension: string;

    if fields.size == 1 || fields[fields.domain.high].count(Path.pathSep) > 0 {
      prefix = filename;
      extension = "";
    } else {
      prefix = ".".join(fields#(fields.size-1)); // take all but the last
      extension = "." + fields[fields.domain.high];
    }

    return (prefix,extension);
  }

  /* Copied verbatim from Arkouda. This is a general helper in Arkouda. */
  /*
   * Generates a list of filenames to be written to based upon a file prefix,
   * extension, and number of locales.
   */
  private proc generateFilenames(prefix : string, extension : string,
                                 targetLocalesSize:int) : [] string throws {
    /*
     * Generates a file name composed of a prefix, which is a filename provided by
     * the user along with a file index and extension.
     */
    proc generateFilename(prefix : string, extension : string,
                          idx : int) : string throws {
        var suffix = '%04i'.format(idx);
        return "%s_LOCALE%s%s".format(prefix, suffix, extension);
    }

    // Generate the filenames based upon the number of targetLocales.
    var filenames: [0..#targetLocalesSize] string;
    for i in 0..#targetLocalesSize {
      filenames[i] = generateFilename(prefix, extension, i);
    }

    return filenames;
  }

  /*
   * Generates an array of filenames to be matched in APPEND mode and to be
   * checked in TRUNCATE mode that will warn the user that 1..n files are
   * being overwritten.
   */
  private proc getMatchingFilenames(prefix : string, extension : string) throws {
      return FS.glob("%s_LOCALE*%s".format(prefix, extension));
  }

}
