local ok, options = pcall(require, "elk.options")
if ok and options then
    options.set({
        trap_aliases = {
            -- base
            ["getc"] = 0x20,
            ["out"] = 0x21,
            ["puts"] = 0x22,
            ["in"] = 0x23,
            ["putsp"] = 0x24,
            ["halt"] = 0x25,
            -- debug
            ["putn"] = 0x26,
            ["reg"] = 0x27,
            -- minecraft
            ["chat"] = 0x28,
            ["getp"] = 0x29,
            ["setp"] = 0x2A,
            ["getb"] = 0x2B,
            ["setb"] = 0x2C,
            ["geth"] = 0x2D,
            -- time
            ["time"] = 0x30,
            ["sleep"] = 0x31,
            -- random
            ["seed"] = 0x3A,
            ["rand"] = 0x3B,
            -- terminal
            ["clear"] = 0x40,
            ["home"] = 0x41,
            ["goto"] = 0x42,
            ["alt"] = 0x43,
            ["cur"] = 0x44,
            ["key"] = 0x45,
            ["poll"] = 0x46,
            -- syscalls
            ["open"] = 0x50,
            ["close"] = 0x51,
            ["read"] = 0x52,
            ["write"] = 0x53,
            ["seek"] = 0x54,
            ["size"] = 0x55,
            ["remove"] = 0x56,
            -- turtle
            ["move"] = 0x60,
            ["turn"] = 0x61,
            ["pen"] = 0x62,
            ["color"] = 0x63,
            ["width"] = 0x64,
            ["dims"] = 0x65,
            ["jump"] = 0x66,
        },
    })
end
