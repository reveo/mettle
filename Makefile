CXXFLAGS := -std=c++1y
PREFIX := /usr

-include config.mk

ifdef MKDOCS_VENV
  MKDOCS := . $(MKDOCS_VENV)/bin/activate && mkdocs
else
  MKDOCS := mkdocs
endif

ifndef TMPDIR
  TMPDIR := /tmp
endif

TEST_DIRS := test test/posix
TESTS := $(patsubst %.cpp,%,$(foreach d,$(TEST_DIRS),$(wildcard $(d)/*.cpp)))
EXAMPLES := $(patsubst %.cpp,%,$(wildcard examples/*.cpp))
HEADER_ONLY_EXAMPLES := examples/test_header_only

METTLE_DIRS := src src/posix
METTLE_SOURCES := $(foreach dir,$(METTLE_DIRS),$(wildcard $(dir)/*.cpp))
LIBMETTLE_DIRS := src/libmettle src/libmettle/log src/libmettle/posix
LIBMETTLE_SOURCES := $(foreach dir,$(LIBMETTLE_DIRS),$(wildcard $(dir)/*.cpp))
SOURCES := $(METTLE_SOURCES) $(LIBMETTLE_SOURCES)
LIBS := -lboost_program_options -lboost_iostreams -pthread

all: mettle libmettle.so

# Include all the existing dependency files for automatic #include dependency
# handling.
-include $(TESTS:=.d)
-include $(EXAMPLES:=.d)
-include $(SOURCES:.cpp=.d)

# Build .o files and the corresponding .d (dependency) files. For more info, see
# <http://scottmcpeak.com/autodepend/autodepend.html>.
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -Iinclude -c $< -o $@
	$(eval TEMP := $(shell mktemp $(TMPDIR)/mettle-XXXXXX))
	@$(CXX) $(CXXFLAGS) -MM -Iinclude $< > $(TEMP)
	@sed -e 's|.*:|$*.o:|' < $(TEMP) > $*.d
	@sed -e 's/.*://' -e 's/\\$$//' < $(TEMP) | fmt -1 | \
	  sed -e 's/^ *//' -e 's/$$/:/' >> $*.d
	@rm -f $(TEMP)

TEST_LDFLAGS := $(LDFLAGS)
test/test_child test/test_cmd_line test/test_test_file: \
  TEST_LDFLAGS += -lboost_program_options
test/test_child: TEST_LDFLAGS += -lboost_iostreams
test/posix/test_subprocess: TEST_LDFLAGS += -lpthread
test/test_test_file: src/test_file.o

$(TESTS) $(filter-out $(HEADER_ONLY_EXAMPLES),$(EXAMPLES)): %: %.o libmettle.so
	$(CXX) $(CXXFLAGS) $(filter %.o,$^) -L. -lmettle $(TEST_LDFLAGS) -o $@

$(HEADER_ONLY_EXAMPLES): %: %.o
	$(CXX) $(CXXFLAGS) $^ $(LDFLAGS) -o $@

examples: $(EXAMPLES)

tests: $(TESTS)

mettle: MY_LDFLAGS := $(LDFLAGS) -lboost_program_options -lboost_iostreams
mettle: $(METTLE_SOURCES:.cpp=.o) libmettle.so
	$(CXX) $(CXXFLAGS) $(filter %.o,$^) -L. -lmettle $(MY_LDFLAGS) -o $@

libmettle.so: CXXFLAGS += -fPIC
libmettle.so: MY_LDFLAGS := $(LDFLAGS) $(LIBS)
libmettle.so: $(LIBMETTLE_SOURCES:.cpp=.o)
	$(CXX) -shared $(CXXFLAGS) $^ -L. $(MY_LDFLAGS) -o $@

.PHONY: install
install: all
	cp -R include $(PREFIX)
	cp mettle $(PREFIX)/bin/mettle
	cp libmettle.so $(PREFIX)/lib/libmettle.so

.PHONY: test
test: tests mettle
	./mettle --output=verbose --color=auto $(TESTS)

.PHONY: doc
doc:
	$(MKDOCS) build --clean

.PHONY: doc-serve
doc-serve:
	$(MKDOCS) serve --dev-addr=0.0.0.0:8000

.PHONY: doc-deploy
doc-deploy:
	$(MKDOCS) gh-deploy --clean

.PHONY: clean
clean: clean-tests clean-examples clean-bin clean-obj

.PHONY: clean-tests
clean-tests:
	rm -f $(TESTS)

.PHONY: clean-examples
clean-examples:
	rm -f $(EXAMPLES)

.PHONY: clean-bin
clean-bin:
	rm -f mettle libmettle.so

.PHONY: clean-obj
clean-obj:
	find . -name "*.[od]" -exec rm -f {} +

.PHONY: gitignore
gitignore:
	@echo $(TESTS) | sed -e 's|test/||g' -e 's/ /\n/g' > test/.gitignore
	@echo $(EXAMPLES) | sed -e 's|examples/||g' -e 's/ /\n/g' > \
	  examples/.gitignore
