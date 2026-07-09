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

ifneq ($(shell pkg-config --exists arrow parquet 2>/dev/null && echo yes),)
  ARROW_CFLAGS := $(shell pkg-config --cflags arrow parquet)
  ARROW_LDFLAGS := $(shell pkg-config --libs arrow parquet)
  ARROW_LIBDIR := $(shell pkg-config --variable=libdir arrow)
endif

ifeq ($(ARROW_CFLAGS),)
  $(error Could not find Arrow/Parquet. Make sure Arrow/Parquet and pkg-config are installed and that pkg-config can find them.)
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
