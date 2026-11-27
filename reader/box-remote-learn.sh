#!/bin/bash
cd /opt/reader
export LUA_PATH="/opt/reader/automation/?.lua;/opt/reader/lua/?.lua;;"
export LUA_CPATH="/opt/reader/build/?.so;/usr/lib/aarch64-linux-gnu/lua/5.1/?.so;;"
exec luajit /opt/reader/box-remote.lua
