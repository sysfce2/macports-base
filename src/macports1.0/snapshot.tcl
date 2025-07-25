# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:filetype=tcl:et:sw=4:ts=4:sts=4
# snapshot.tcl
#
# Copyright (c) 2017 The MacPorts Project
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. Neither the name of Apple Inc. nor the names of its contributors
#    may be used to endorse or promote products derived from this software
#    without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

package provide snapshot 1.0

package require macports 1.0
package require registry 1.0
package require json
package require json::write

namespace eval snapshot {
    proc print_usage {} {
        ui_msg "Usage: One of:"
        ui_msg "  port snapshot \[--create\] \[--note '<message>'\]"
        ui_msg "  port snapshot --list"
        ui_msg "  port snapshot --diff <snapshot-id> \[--all\]"
        ui_msg "  port snapshot --delete <snapshot-id>"
        ui_msg "  port snapshot --export <snapshot-id> >snapshot.json"
        ui_msg "  port snapshot --import snapshot.json"
    }

    proc main {opts} {
        # Function to create a snapshot of the current state of ports.
        #
        # Args:
        #           opts - The options passed in.
        # Returns:
        #           registry::snapshot

        if {[dict exists $opts ports_snapshot_help]} {
            print_usage
            return 0
        }

        set operation ""
        foreach op {list create diff delete export import} {
            set optname ports_snapshot_$op
            if {[dict exists $opts $optname]} {
                if {$operation ne ""} {
                    ui_error "Only one of the --list, --create, --diff, --delete, --export, or --import options can be specified."
                    error "Incorrect usage, see port snapshot --help."
                }
                set operation $op
            }
        }

        switch $operation {
            "" -
            "create" {
                if {[catch {create $opts} result]} {
                    ui_error "Failed to create snapshot: $result"
                    return 1
                }
                return 0
            }
            "list" {
                set snapshots [registry::snapshot get_all]

                if {[llength $snapshots] == 0} {
                    if {![macports::ui_isset ports_quiet]} {
                        ui_msg "There are no snapshots. Use 'sudo port snapshot \[--create\] \[--note '<message>'\]' to create one."
                    }
                    return 0
                }

                # Convert UTC datetimes to local timezone
                set timestamps [dict create]
                foreach snapshot $snapshots {
                    set created_at_seconds [clock scan [$snapshot created_at] -timezone :UTC -format "%Y-%m-%d %T"]
                    dict set timestamps $snapshot [clock format $created_at_seconds -format "%Y-%m-%d %T%z"]
                }

                set lens [dict create id [string length "ID"] created_at [string length "Created"] note [string length "Note"]]
                foreach snapshot $snapshots {
                    foreach fieldname {id note} {
                        set len [string length [$snapshot $fieldname]]
                        if {[dict get $lens $fieldname] < $len} {
                            dict set lens $fieldname $len
                        }
                    }
                    set len [string length [dict get $timestamps $snapshot]]
                    if {[dict get $lens created_at] < $len} {
                        dict set lens created_at $len
                    }
                }

                set formatStr "%*s  %-*s  %-*s"
                set heading [format $formatStr [dict get $lens id] "ID" [dict get $lens created_at] "Created" [dict get $lens note] "Note"]

                if {![macports::ui_isset ports_quiet]} {
                    ui_msg $heading
                    ui_msg [string repeat "=" [string length $heading]]
                }
                foreach snapshot $snapshots {
                    ui_msg [format $formatStr [dict get $lens id] [$snapshot id] [dict get $lens created_at] [dict get $timestamps $snapshot] [dict get $lens note] [$snapshot note]]
                }

                return 0
            }
            "diff" {
                if {[catch {set snapshot [registry::snapshot get_by_id [dict get $opts ports_snapshot_diff]]} result]} {
                    ui_error "Failed to obtain snapshot with ID [dict get $opts ports_snapshot_diff]: $result"
                    return 1
                }
                array set diff [diff $snapshot]
                set show_all [dict exists $opts ports_snapshot_all]
                set note ""

                if {!$show_all} {
                    append note "Showing differences in requested ports only. Re-run with --all to see all differences.\n"

                    foreach field {added removed changed} {
                        set result {}
                        foreach port $diff($field) {
                            lassign $port _ requested
                            if {$requested} {
                                lappend result $port
                            }
                        }
                        set diff($field) $result
                    }
                }

                if {[llength $diff(added)] > 0} {
                    append note "The following ports are installed but not in the snapshot:\n"
                    foreach added_port [lsort -ascii -index 0 $diff(added)] {
                        lassign $added_port name _ _ _ requested_variants
                        if {$requested_variants ne ""} {
                            append note " - $name\n"
                        } else {
                            append note " - $name $requested_variants\n"
                        }
                    }
                }

                if {[llength $diff(removed)] > 0} {
                    append note "The following ports are in the snapshot but not installed:\n"
                    foreach removed_port [lsort -ascii -index 0 $diff(removed)] {
                        lassign $removed_port name _ _ _ requested_variants
                        if {$requested_variants ne ""} {
                            append note " - $name\n"
                        } else {
                            append note " - $name $requested_variants\n"
                        }
                    }
                }

                if {[llength $diff(changed)] > 0} {
                    append note "The following ports are in the snapshot and installed, but with changes:\n"
                    foreach changed_port [lsort -ascii -index 0 $diff(changed)] {
                        lassign $changed_port name _ _ _ requested_variants changes
                        if {$requested_variants ne ""} {
                            append note " - $name\n"
                        } else {
                            append note " - $name $requested_variants\n"
                        }
                        foreach change $changes {
                            lassign $change field old new
                            append note "   $field changed from '$old' to '$new'\n"
                        }
                    }
                }

                if {[llength $diff(added)] == 0 && [llength $diff(removed)] == 0 && [llength $diff(changed)] == 0} {
                    append note "The current state and the specified snapshot match.\n"
                }

                ui_msg [string trimright $note "\n"]
                return 0
            }
            "delete" {
                return [delete_snapshot [dict get $opts ports_snapshot_delete]]
            }
            "export" {
                if {[catch {set snapshot [registry::snapshot get_by_id [dict get $opts ports_snapshot_export]]} result]} {
                    ui_error "Failed to obtain snapshot with ID [dict get $opts ports_snapshot_export]: $result"
                    return 1
                }

                puts [snapshot2json $snapshot]
            }
            "import" {
                set filename [dict get $opts ports_snapshot_import]
                try {
                    set fp [open $filename r]
                    set contents [read $fp]
                    close $fp
                } on error {eMessage} {
                    ui_error "Failed to read $filename: $eMessage"
                    return 1
                }

                try {
                    set snapshot [import $contents $opts]
                } on error {eMessage} {
                    ui_error "Import failed: $eMessage"
                    return 1
                }

                ui_msg "Snapshot successfully imported with ID [$snapshot id]."
                ui_msg "To restore this snapshot now, run\n\tsudo port restore --snapshot-id [$snapshot id]"

                return 0
            }
            default {
                print_usage
                return 1
            }
        }
    }

    proc snapshot2json {snapshot} {
        # Convert the given snapshot to JSON format and return it
        #
        # The data format is
        #
        #   metadata:
        #     type: string "org.macports/snapshot/v1", denoting the version of this format
        #     note: string, the note associated with this snapshot
        #     created_at: string, the local date at which the snapshot was created
        #   ports:
        #     list of objects:
        #       port_name: string, the name of the port
        #       requested: int, 1 for ports that are requested, 0 otherwise
        #       state: string, "installed" for ports that are active
        #       variants: string, list of active variants
        #       requested_variants: string, list of variants requested by the user
        #       port_files: list of strings, the files installed by this port
        #
        # Args:
        #           snapshot - The snapshot object to convert to JSON
        # Returns:
        #           string representation of the snapshot object

        # The conversion can take quite a while because we're querying all
        # files installed by the various ports, so display a progress bar
        set fancy_output [expr {![macports::ui_isset ports_debug] && [info exists macports::ui_options(progress_generic)]}]
        if {$fancy_output} {
            set progress $macports::ui_options(progress_generic)
        } else {
            proc noop {args} {}
            set progress noop
        }
        set counter 0
        set total [llength [$snapshot ports]]

        # Add some metadata and a version header that allows us to make
        # backwards-incompatible changes to the output format.
        set metadata [json::write object-strings \
            type "org.macports/snapshot/v1" \
            note [$snapshot note] \
            created_at [$snapshot created_at]]

        $progress start
        $progress update $counter $total

        # Convert each port into its JSON representation
        set ports [list]
        foreach port [$snapshot ports] {
            incr counter

            lassign $port port_name requested state variants requested_variants
            set files [snapshot::port_files [$snapshot id] $port_name]

            ui_debug "Processing port $counter/$total: $port_name"

            lappend ports [json::write object \
                port_name [json::write string $port_name] \
                requested $requested \
                state [json::write string $state] \
                variants [json::write string $variants] \
                requested_variants [json::write string $requested_variants] \
                port_files [json::write array-strings {*}$files]]

            $progress update $counter $total
        }

        # Assemble the metadata and port list into the final JSON object and
        # return it.
        set res [json::write object \
            metadata $metadata \
            ports [json::write array {*}$ports]]
        $progress finish
        return $res
    }

    proc _last_insert_rowid {con} {
        # Obtain the last insert rowid from the given SQLite database
        # connection and return it
        #
        # Args:
        #           con - The database connection
        # Returns:
        #           the result of SELECT last_insert_rowid()
        variable last_insert_rowid_stmt
        if {![info exists last_insert_rowid_stmt]} {
            set last_insert_rowid_stmt [$con prepare {
                SELECT last_insert_rowid()
            }]
        }

        set results [$last_insert_rowid_stmt execute]
        $results nextlist row
        lassign $row rowid
        $results close
        return $rowid
    }

    proc import {contents opts} {
        # Import the snapshot in JSON encoding given in contents into the
        # database and return the imported snapshot object.
        #
        # Args:
        #           contents - The JSON encoded snapshot as a string
        #           opts - Options dict
        # Returns:
        #           The imported snapshot as a snapshot object

        set data [json::json2dict $contents]

        try {
            set type [dict get $data metadata type]
        } on error {eMessage} {
            error "Invalid format: no metadata/type field"
        }

        switch $type {
            "org.macports/snapshot/v1" {
                # This is the only supported version, processing continues below
            }
            default {
                error "Invalid format: unsupported type $type, possibly generated by a newer version of MacPorts"
            }
        }

        global registry::tdbc_connection
        variable import_snapshot_stmt
        variable import_port_stmt
        variable import_file_stmt
        if {![info exists import_snapshot_stmt]} {
            set import_snapshot_stmt [$tdbc_connection prepare {
                INSERT INTO snapshots (
                      created_at
                    , note
                ) VALUES (
                      :created_at
                    , :note
                )
            }]
        }
        if {![info exists import_port_stmt]} {
            set import_port_stmt [$tdbc_connection prepare {
                INSERT INTO snapshot_ports (
                      snapshots_id
                    , port_name
                    , requested
                    , state
                    , variants
                    , requested_variants
                ) VALUES (
                      :snapshot_id
                    , :port_name
                    , :requested
                    , :state
                    , :variants
                    , :requested_variants
                )
            }]
        }
        if {![info exists import_file_stmt]} {
            set import_file_stmt [$tdbc_connection prepare {
                INSERT INTO snapshot_files (
                      id
                    , path
                ) VALUES (
                      :port_id
                    , :path
                )
            }]
        }

        set created_at [dict get $data metadata created_at]
        set note [dict get $data metadata note]
        set ports [dict get $data ports]

        set counter 0
        set total [llength $ports]

        set fancy_output [expr {![macports::ui_isset ports_debug] && [info exists macports::ui_options(progress_generic)]}]
        if {$fancy_output} {
            set progress $macports::ui_options(progress_generic)
        } else {
            proc noop {args} {}
            set progress noop
        }

        $progress start
        $progress update $counter $total

        $tdbc_connection transaction {
            $import_snapshot_stmt execute
            set snapshot_id [_last_insert_rowid $tdbc_connection]

            foreach port $ports {
                incr counter
                ui_debug "Processing port $counter/$total: [dict get $port port_name]"

                dict set port snapshot_id $snapshot_id

                $import_port_stmt execute $port
                set port_id [_last_insert_rowid $tdbc_connection]

                foreach path [dict get $port port_files] {
                    $import_file_stmt execute
                }

                $progress update $counter $total
            }
        }

        $progress finish

        return [registry::snapshot get_by_id $snapshot_id]
    }

    proc create {opts} {

        registry::write {
            # An option used by user while creating snapshot manually
            # to identify a snapshot, usually followed by `port restore`
            if {[dict exists $opts ports_snapshot_note]} {
                set note [join [dict get $opts ports_snapshot_note]]
            } else {
                set note "snapshot created for migration"
            }
            set inactive_ports [list]
            foreach port [registry::entry imaged] {
                if {[$port state] eq "imaged"} {
                    lappend inactive_ports "[$port name] @[$port version]_[$port revision] [$port variants]"
                }
            }
            if {[llength $inactive_ports] != 0} {
                set msg "The following inactive ports will not be a part of this snapshot and won't be installed while restoring:"
                set inactive_ports [lsort -index 0 -nocase $inactive_ports]
                if {[info exists macports::ui_options(questions_yesno)]} {
                    set retvalue [$macports::ui_options(questions_yesno) $msg "Continue?" $inactive_ports {y} 0]
                    if {$retvalue != 0} {
                        ui_msg "Not creating a snapshot!"
                        return 0
                    }
                } else {
                    puts $msg
                    foreach port $inactive_ports {
                        puts $port
                    }
                }
            }
            set snapshot [registry::snapshot create $note]
        }
        return $snapshot
    }

    # Remove a snapshot from the registry. Not called 'delete' to avoid
    # confusion with the proc in portutil.
    proc delete_snapshot {snapshot_id} {
        global registry::tdbc_connection
        if {[catch {registry::snapshot get_by_id $snapshot_id}]} {
            ui_error "No such snapshot ID: $snapshot_id"
            return 1
        }
        # relies on cascading delete to also remove snapshot ports and files
        set query {DELETE FROM snapshots WHERE id = :snapshot_id}
        set stmt [$tdbc_connection prepare $query]
        $tdbc_connection transaction {
            set results [$stmt execute]
        }
        if {[$results rowcount] < 1} {
            ui_warn "delete_snapshot: no rows were deleted for snapshot ID: $snapshot_id"
        } else {
            registry::set_needs_vacuum
        }
        $results close
        $stmt close
        return 0
    }

    # Get the port name that owns the given file path in the given snapshot.
    proc file_owner {path snapshot_id} {
        global registry::tdbc_connection
        variable file_owner_stmt
        if {![info exists file_owner_stmt]} {
            set query {SELECT snapshot_ports.port_name FROM snapshot_ports
                    INNER JOIN snapshot_files ON snapshot_files.id = snapshot_ports.id
                    WHERE snapshot_files.path = :path AND snapshot_ports.snapshots_id = :snapshot_id}
            set file_owner_stmt [$tdbc_connection prepare $query]
        }
        $tdbc_connection transaction {
            set results [$file_owner_stmt execute]
        }
        set ret [lmap l [$results allrows] {lindex $l 1}]
        $results close
        return $ret
    }

    proc port_files {snapshot_id port_name} {
        global registry::tdbc_connection
        variable port_files_stmt
        if {![info exists port_files_stmt]} {
            set port_files_stmt [$tdbc_connection prepare {
                    SELECT snapshot_files.path FROM snapshot_files
                    INNER JOIN snapshot_ports ON snapshot_files.id = snapshot_ports.id
                    WHERE snapshot_ports.port_name = :port_name
                    AND snapshot_ports.snapshots_id = :snapshot_id
                    ORDER BY snapshot_files.path ASC
            }]
        }
        $tdbc_connection transaction {
            set results [$port_files_stmt execute]
        }
        set ret [lmap l [$results allrows] {lindex $l 1}]
        $results close
        return $ret
    }

    proc _os_mismatch {iplatform iosmajor} {
        global macports::os_platform macports::os_major
        if {$iplatform ne "any" && ($iplatform ne $os_platform
            || ($iosmajor ne "any" && $iosmajor != $os_major))
        } then {
            return 1
        }
        return 0
    }

    proc _find_best_match {port installed} {
        lassign $port name requested active variants requested_variants
        set active [expr {$active eq "installed"}]
        set requested [expr {$requested == 1}]

        set best_match {}
        set best_match_score -1
        foreach regref $installed {
            set ivariants [$regref variants]
            set iactive [expr {[$regref state] eq "installed"}]
            set irequested [expr {[$regref requested] == 1}]
            set irequested_variants [$regref requested_variants]

            if {[_os_mismatch [$regref os_platform] [$regref os_major]]} {
                # ignore ports that were not built on the current macOS version
                continue
            }

            set score 0

            if {$irequested_variants eq $requested_variants} {
                incr score
            }
            if {$irequested == $requested} {
                incr score
            }
            if {$ivariants eq $variants} {
                incr score
            }
            if {$active == $iactive} {
                incr score
            }

            if {$score > $best_match_score} {
                set best_match_score $score
                set best_match [list [$regref name] [$regref version] \
                    [$regref revision] $ivariants $iactive [$regref epoch] \
                    $irequested $irequested_variants]
            }
        }

        return $best_match
    }

    ##
    # Compute the difference between the given snapshot registry object, and
    # the currently installed ports.
    #
    # Callers that do not care about differences in unrequested ports are
    # expected to filter the results themselves.
    #
    # Args:
    #       snapshot - The snapshot object
    # Returns:
    #       A array in list form with the three entries removed, added, and
    #       changed. Each array value is a list with entries that were removed,
    #       added, or changed. The format is as follows:
    #       - Added entries: a 5-tuple of (name, requested, active, variants, requested variants)
    #       - Removed entries: a 5-tuple of (name, requested, active, variants, requested variants)
    #       - Changed entries: a 6-typle of (name, requested, active, variants, requested variants, changes)
    #       where changes is a list of 3-tuples of (changed field, old value, new value)
    proc diff {snapshot} {
        set portlist [$snapshot ports]

        set removed {}
        set added {}
        set changed {}

        set snapshot_ports [dict create]

        foreach port $portlist {
            lassign $port name requested active variants requested_variants
            set active [expr {$active eq "installed"}]
            set requested [expr {$requested == 1}]

            dict set snapshot_ports $name 1

            if {[catch {set installed [registry::entry imaged $name]}] || $installed eq ""} {
                # registry::installed failed, the port probably isn't installed
                lappend removed $port
                continue
            }

            if {$active} {
                # for ports that were active in the snapshot, always compare
                # with the installed active port, if any
                set found 0
                foreach regref $installed {
                    if {[_os_mismatch [$regref os_platform] [$regref os_major]]} {
                        # ignore ports that were not built on the current macOS version
                        continue
                    }

                    if {[$regref state] eq "installed"} {
                        set irequested [expr {[$regref requested] == 1}]
                        set ivariants [$regref variants]
                        set irequested_variants [$regref requested_variants]
                        set found 1
                        break
                    }
                }

                if {$found} {
                    set changes {}
                    if {$requested_variants ne $irequested_variants} {
                        lappend changes [list "requested variants" $requested_variants $irequested_variants]
                    }
                    if {$variants ne $ivariants} {
                        lappend changes [list "variants" $variants $ivariants]
                    }
                    if {$requested != $irequested} {
                        lappend changes [list "requested" \
                            [expr {$requested == 1 ? "requested" : "unrequested"}] \
                            [expr {$irequested == 1 ? "requested" : "unrequested"}]]
                    }
                    if {[llength $changes] > 0} {
                        lappend changed [list {*}$port $changes]
                    }
                    continue
                }
            }

            # Either the port wasn't active in the snapshot, or the port is now no longer active.
            # This may still mean that it is missing completely, e.g., because only the version for an older OS is installed
            set best_match [_find_best_match $port $installed]
            if {[llength $best_match] <= 0} {
                # There is no matching port, so it seems this one is actually missing
                lappend removed $port
                continue
            } else {
                lassign $best_match iname iversion irevision ivariants iactive iepoch irequested irequested_variants

                set changes {}
                if {$requested_variants ne $irequested_variants} {
                    lappend changes [list "requested variants" $requested_variants $irequested_variants]
                }
                if {$variants ne $ivariants} {
                    lappend changes [list "variants" $variants $ivariants]
                }
                if {$requested != $irequested} {
                    lappend changes [list "requested" \
                        [expr {$requested == 1 ? "requested" : "unrequested $requested"}] \
                        [expr {$irequested == 1 ? "requested" : "unrequested $irequested"}]]
                }
                if {$active != $iactive} {
                    lappend changes [list "state" \
                        [expr {$active == 1 ? "installed" : "inactive"}] \
                        [expr {$iactive == 1 ? "installed" : "inactive"}]]
                }
                if {[llength $changes] > 0} {
                    lappend changed [list {*}$port $changes]
                }
            }
        }

        foreach regref [registry::entry imaged] {
            if {[_os_mismatch [$regref os_platform] [$regref os_major]]} {
                # port was installed on old OS, ignore
                continue
            }
            set iname [$regref name]
            if {[dict exists $snapshot_ports $iname]} {
                # port was in the snapshot
                continue
            }

            # port was not in the snapshot, it is new
            set iactive [expr {[$regref state] eq "installed"}]
            lappend added [list $iname [$regref requested] $iactive [$regref variants] [$regref requested_variants]]
        }

        return [list removed $removed added $added changed $changed]
    }
}
