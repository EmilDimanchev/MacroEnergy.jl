function default_system_data()
    return Dict{Symbol,Any}(
        :assets => Dict{Symbol,Any}(:path => "assets"),
        :locations => Dict{Symbol,Any}(:path => "system/locations.json"),
        :nodes => Dict{Symbol,Any}(:path => "system/nodes.json"),
        :commodities => Dict{Symbol,Any}(:path => "system/commodities.json"),
        :time_data => Dict{Symbol,Any}(:path => "system/time_data.json"),
        :settings => Dict{Symbol,Any}(:path => "settings/macro_settings.json"),
    )
end

"""
    load_default_system_data()::Dict{Symbol,Any}

Load the default system data from a JSON file. 
This describes the default locations for the system data files.
"""
function load_default_system_data()::Dict{Symbol,Any}
    return default_system_data()
end

"""
    add_default_system_data!(system_data::AbstractDict{Symbol,Any})::Nothing

Add the default system data to the system data dictionary. This adds any required fields that are missing.
"""
function add_default_system_data!(system_data::AbstractDict{Symbol,Any})::Nothing
    default_system_data = load_default_system_data()
    merge!(default_system_data, system_data)
    return nothing
end

"""
    prep_system_data(file_path::AbstractString)::Nothing

This attempts to load the system data from the file at file_path, adds any missing fields from the default system data, and writes the updated system data back to the file.
In the future, we may change this to not write to the file, but for now, it's a quick way to ensure the system data is up-to-date.
"""
function prep_system_data(file_path::AbstractString)::Nothing
    if isfile(file_path)
        system_data = read_json(file_path)
        @debug("Loading system data from $file_path")
        add_default_system_data!(system_data)
    else
        @warn("No system data file found at $file_path.\nUsing default system data")
        system_data = load_default_system_data()
    end

    # FIXME currently overwriting and then re-reading the system_data
    # This is a little janky, but lets us quickly use the JSON parsing functions
    updated = sprint(io -> JSON3.pretty(io, system_data))
    isfile(file_path) && read(file_path, String) == updated && return nothing

    # Write to a temporary file and rename it into place, so that other runs
    # reading the same file (e.g. parallel jobs) never see it truncated.
    @debug("Writing updated system data to $file_path")
    tmp_path, io = mktemp(dirname(file_path); cleanup=false)
    try
        write(io, updated)
        close(io)
        # mktemp creates the file as owner-only; keep the original permissions
        chmod(tmp_path, isfile(file_path) ? filemode(file_path) & 0o777 : 0o644)
        mv(tmp_path, file_path; force=true)
    catch
        close(io)
        rm(tmp_path; force=true)
        rethrow()
    end
    return nothing
end