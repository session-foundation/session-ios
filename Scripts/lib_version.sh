#!/usr/bin/env bash
#
# lib_version.sh — shared helpers for reading the project-level (inherited) version
# from project.pbxproj. Sourced by the release scripts; not executed directly.
#
# Version numbers are set on the PBXProject's App_Store_Release configuration and
# inherited by the app + extension targets, so these read that one block. The config
# list that identifies the project-level block appears *after* the block itself in the
# file, so we resolve the GUID first (pass 1) then read the block (pass 2).

# read_project_version <pbx-path> <setting-key>  ->  echoes the value (e.g. 2.15.3)
read_project_version() {
    local pbx="$1" key="$2" guid
    guid=$(awk '
        /Build configuration list for PBXProject .*= \{/ { inlist=1 }
        inlist && /App_Store_Release \*\/,/ { match($0,/[A-F0-9]{24}/); print substr($0,RSTART,RLENGTH); exit }
    ' "$pbx")
    [ -n "$guid" ] || return 1
    awk -v guid="$guid" -v key="$key" '
        $0 ~ "^\t\t"guid" \\/\\* App_Store_Release \\*\\/ = \\{" { inblock=1 }
        inblock && $0 ~ "[[:space:]]"key" = " { v=$0; sub(/.*= /,"",v); sub(/;.*/,"",v); print v; exit }
        inblock && /^\t\t\};/ { exit }
    ' "$pbx"
}
