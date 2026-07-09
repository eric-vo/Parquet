CXX = g++
CHPL_CXX = $(shell $(ARKOUDA_CHPL_HOME)/util/config/compileline --compile-c++ 2>/dev/null)
ifeq ($(CHPL_CXX),)
CHPL_CXX=$(CXX)
endif

# trick from https://www.systutorials.com/how-to-get-the-full-path-and-directory-of-a-makefile-itself/#:~:text=ByEric%20Ma%20Mar%2024,Read%20more:
MKFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
MKFILE_DIR := $(dir $(MKFILE_PATH))

INCDIR = $(MKFILE_DIR)/include
SRCDIR = $(MKFILE_DIR)/src
OBJDIR = $(MKFILE_DIR)/obj

CXX_HEADERS = $(wildcard $(INCDIR)/*.h)
CXX_SOURCES = $(wildcard $(SRCDIR)/*.cpp)
CXX_OBJECTS = $(patsubst $(SRCDIR)/%.cpp,$(OBJDIR)/%.o,$(CXX_SOURCES))

CXXFLAGS=-I$(INCDIR) -std=c++20
# Build prereq objects as PIC so they can be linked into PIE executables.
# Override at invocation time if needed (e.g., PIC_CXXFLAGS="").
PIC_CXXFLAGS ?= -fPIC

# --- Arrow/Parquet dependency resolution ---
# Priority: 1) ARROW_DIR env var, 2) pkg-config, 3) spack
# Helper: detect lib64 vs lib for a given prefix (returns empty if neither has Arrow libs)
_has_arrow_libs = $(or $(wildcard $(1)/libarrow.so*),$(wildcard $(1)/libarrow.dylib*),$(wildcard $(1)/libarrow.a))
_arrow_libdir = $(if $(call _has_arrow_libs,$(1)/lib64),$(1)/lib64,$(if $(call _has_arrow_libs,$(1)/lib),$(1)/lib,))

ifdef ARROW_DIR
  ARROW_LIBDIR := $(call _arrow_libdir,$(ARROW_DIR))
  ARROW_CFLAGS := -I$(ARROW_DIR)/include
  ARROW_LDFLAGS := -L$(ARROW_LIBDIR) -larrow -lparquet
else ifneq ($(shell pkg-config --exists arrow parquet 2>/dev/null && echo yes),)
  ARROW_CFLAGS := $(shell pkg-config --cflags arrow parquet)
  ARROW_LDFLAGS := $(shell pkg-config --libs arrow parquet)
  ARROW_LIBDIR := $(shell pkg-config --variable=libdir arrow)
else ifneq ($(shell command -v spack 2>/dev/null),)
  _SPACK_ARROW_PREFIX := $(shell spack find --limit=1 --format="{prefix}" arrow 2>/dev/null)
  ifneq ($(_SPACK_ARROW_PREFIX),)
    ARROW_LIBDIR := $(call _arrow_libdir,$(_SPACK_ARROW_PREFIX))
    ARROW_CFLAGS := -I$(_SPACK_ARROW_PREFIX)/include
    ARROW_LDFLAGS := -L$(ARROW_LIBDIR) -larrow -lparquet
  endif
endif

ifeq ($(ARROW_CFLAGS),)
  $(error Could not find Arrow/Parquet. Set ARROW_DIR, install pkg-config files, or use spack.)
endif

ifeq ($(ARROW_LIBDIR),)
  $(error Arrow/Parquet libraries not found in lib/ or lib64/. Verify your Arrow installation.)
endif

CXXFLAGS+=$(ARROW_CFLAGS)
CXXFLAGS+=$(PIC_CXXFLAGS)

# also add the src directory to be able to include SharedEnums without
# relative path. This path is relative to prereqs/cpp
CXXFLAGS+=-I../../src/util

.PHONY: all clean

all: $(CXX_OBJECTS)

# Note -I./src is to be able to use SharedEnums.chpl. This path is relative to
# the project root
printchplflags:
	@$(info $(CXX_HEADERS) $(CXX_OBJECTS) -I./src/util/ --ldflags -Wl,-rpath --ldflags $(ARROW_LIBDIR) $(ARROW_LDFLAGS))

# Rule to create object directory if it doesn't exist
$(OBJDIR):
	mkdir -p $(OBJDIR)

# Rule to compile C++ source files into object files
$(OBJDIR)/%.o: $(SRCDIR)/%.cpp | $(OBJDIR)
	$(CHPL_CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -rf $(OBJDIR)
