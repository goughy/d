--require "d"
LuaD = "/data/devel-ext/LuaD"

solution "http4d"
    configurations { "debug", "release" }
    includedirs { "src", "src/deimos" } 

    configuration "debug"
        flags { "Symbols", "ExtraWarnings" }

    configuration { "debug", "D" }
        buildoptions "-gc"
        buildoptions "-Dddoc"

    configuration "release"
        flags { "Optimize" }

    configuration "test"
        buildoptions "-unittest"
        flags { "Symbols", "ExtraWarnings" }

    project "http4d"
        kind "ConsoleApp"
        language "D"
        files { "main.d", "src/protocol/*.d" }
        links { "zmq" }

    project "lua"
        kind "StaticLib"
        language "C"
        files { "src/luasp/lua-5.1/src/*.c" }
        excludes { "src/luasp/lua-5.1/src/lua.c", "src/luasp/lua-5.1/src/luac.c", "src/luasp/lua-5.1/src/print.c" }
        buildoptions "-fno-omit-frame-pointer"

    project "lsp"
        kind "ConsoleApp"
        language "D"
--        buildoptions "-v"
        includedirs { LuaD }
        files { "examples/luasp/lsp.d", "src/protocol/*.d", "src/luasp/*.d" }
        files { LuaD .. "/luad/*.d", LuaD .. "/luad/conversions/*.d", LuaD .. "/luad/c/*.d" }
        links { "lua", "zmq" }

    project "lsp_standalone"
        kind "ConsoleApp"
        language "D"
        includedirs { LuaD }
        files { "examples/luasp/lsp_standalone.d", "src/luasp/process.d" }
        files { LuaD .. "/luad/*.d", LuaD .. "/luad/conversions/*.d", LuaD .. "/luad/c/*.d" }
        links { "lua" }

    project "client"
        kind "ConsoleApp"
        language "D"
        buildoptions { "-unittest" }
        files { "client.d" }
        files { "src/protocol/*.d" }
        links { "zmq" }

    project "autoroute"
        kind "ConsoleApp"
        language "D"
--        buildoptions { "-unittest" }
        files { "examples/autoroute.d" }
        files { "src/protocol/*.d" }
        links { "zmq" }

--[[
    project "ex1"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex1.d" }
        links { "http4d", "zmq" }

    project "ex2"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex2.d" }
        links { "http4d", "zmq" }

    project "ex3"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex3.d" }
        links { "http4d", "zmq" }

    project "ex4"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex4.d" }
        links { "http4d", "zmq" }
--]]

