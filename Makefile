#
# Generic Apple /// device driver builder
#
# Requires ca65/ld65 as part of the cc65 toolchain
# Output is a .o65 file suitable for insertion as
# a SOS driver after conversion to SOS relocatable
# format
#

.DEFAULT_GOAL := all

CA65 := ca65
LD65 := ld65

CA65FLAGS :=
LD65FLAGS :=
CONFIG := Apple3_o65.cfg

# Recursively find matching source files without following directory symlinks.
SOURCES := $(sort $(patsubst ./%,%,$(shell find . -type f -name '*.s')))
OBJECTS := $(SOURCES:.s=.o)
LISTINGS := $(SOURCES:.s=.lst)
TARGETS := $(SOURCES:.s=.o65)

.PHONY: all clean

all: $(TARGETS)

# Keep intermediate object files for incremental builds.
.SECONDARY: $(OBJECTS)

%.o: %.s
	$(CA65) $(CA65FLAGS) "$<" -l "$*.lst" -o "$@"

%.o65: %.o $(CONFIG)
	$(LD65) $(LD65FLAGS) "$<" -o "$@" -C "$(CONFIG)"

clean:
	$(RM) $(OBJECTS) $(TARGETS) $(LISTINGS)
