LUADIR := vendor/lua-5.4.7/src
CC ?= cc
CFLAGS ?= -O2
OWN_CFLAGS := $(CFLAGS) -Wall -Wextra -I$(LUADIR)
LUA_SRCS := $(filter-out $(LUADIR)/lua.c $(LUADIR)/luac.c,$(wildcard $(LUADIR)/*.c))
BUILD := build
LUA_OBJS := $(patsubst $(LUADIR)/%.c,$(BUILD)/lua_%.o,$(LUA_SRCS))
OWN_OBJS := $(BUILD)/main.o $(BUILD)/luna_core.o
BIN := bin/luna-host

all: $(BIN)

$(BIN): $(LUA_OBJS) $(OWN_OBJS)
	@mkdir -p bin
	$(CC) -o $@ $^ -lm -ldl

$(BUILD)/lua_%.o: $(LUADIR)/%.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -std=gnu99 -DLUA_USE_LINUX -w -I$(LUADIR) -c -o $@ $<

$(BUILD)/%.o: src/%.c
	@mkdir -p $(BUILD)
	$(CC) $(OWN_CFLAGS) -c -o $@ $<

test: $(BIN)
	@set -e; for t in tests/rt_*.lua; do echo "== $$t"; LUNA_LUA_DIR=$(CURDIR)/lua $(BIN) --eval $$t; done; echo "ALL RT TESTS PASSED"
	@set -e; for t in $$(ls tests/cdp_*.lua | LC_ALL=C sort); do echo "== $$t"; LUNA_LUA_DIR=$(CURDIR)/lua $(BIN) --eval $$t; done; echo "ALL CDP TESTS PASSED"

clean:
	rm -rf $(BUILD) bin

.PHONY: all test clean
