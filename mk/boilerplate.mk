#################################################################################
#
#			    mk/boilerplate.mk
#
#		The Glorious fptools Boilerplate Makefile
#
# This one file should be included (directly or indirectly) by all Makefiles 
# in the fptools hierarchy.
#
#################################################################################

# We want to disable all the built-in rules that make uses; having them
# just slows things down, and we write all the rules ourselves.
# Setting .SUFFIXES to empty disables them all.
MAKEFLAGS += --no-builtin-rules

# FPTOOLS_TOP is the *relative* path to the fptools toplevel directory from the
# location where a project Makefile was invoked. It is set by looking at the
# current value of TOP.
#
FPTOOLS_TOP := $(TOP)


# This rule makes sure that "all" is the default target, regardless of where it appears
#		THIS RULE MUST REMAIN FIRST!
default: all


# -----------------------------------------------------------------------------
# 	make sure the autoconf stuff is up to date...

$(TOP)/mk/config.mk : $(TOP)/mk/config.mk.in $(TOP)/mk/config.h.in $(TOP)/configure 
	@if test ! -f $(FPTOOLS_TOP)/config.status; then \
		echo "You haven't run $(FPTOOLS_TOP)/configure yet."; \
		exit 1; \
	fi
	@echo "Running $(FPTOOLS_TOP)/config.status to update configuration info..."
	@( cd $(FPTOOLS_TOP) && ./config.status )

$(TOP)/configure : $(TOP)/configure.in $(TOP)/aclocal.m4
	@echo "Regenerating $(FPTOOLS_TOP)/configure..."
	@( cd $(FPTOOLS_TOP) && $(MAKE) -f Makefile.config ./configure )

# -----------------------------------------------------------------------------
# 	Now follow the pieces of boilerplate
#	The "-" signs tell make not to complain if they don't exist

include $(TOP)/mk/config.mk
# All configuration information
#	(generated by "configure" from config.mk.in)
#


include $(TOP)/mk/paths.mk
# Variables that say where things belong (e.g install directories)
# and where we are right now
# Also defines variables for standard files (SRCS, LIBS etc)


include $(TOP)/mk/opts.mk
# Variables that control the option flags for all the
# language processors

ifeq "$(BootingFromHc)" "YES"
include $(TOP)/mk/bootstrap.mk
endif

-include $(TOP)/mk/build.mk
# (Optional) build-specific configuration
#

ifndef FAST
-include .depend
endif
# The dependencies file from the current directory

