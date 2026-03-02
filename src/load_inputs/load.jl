###### ###### ###### ###### ###### ######
# Functions to handle loading MacroEnergy object data
###### ###### ###### ###### ###### ######

# Load data from a JSON file into a System
function load!(system::System, file_path::AbstractString)::Nothing
    file_path = rel_or_abs_path(file_path, system.data_dirpath)
    if isfile(file_path)
        load!(system, load_inputs(file_path))
    elseif isdir(file_path)
        files = get_json_files(file_path)
        files = sort(files, by = x -> occursin("_retrofit_option", x) ? 0 : 1) # Sorts files so that retrofit options are loaded first
        for file in files
            load!(system, joinpath(file_path, file))
        end
    end
    return nothing
end

# Load a single instance of an asset, location, etc. into a System
function load!(system::System, data::AbstractDict{Symbol,Any})::Nothing
    if data_is_system_data(data)
        # println("Loading system data")
        load_system_data!(system, data)

    elseif data_has_global_data(data)
        # println("Expanding global data")
        load!(system, merge_global_data(data))

    # Check that data has only :type and :instance_data fields
    elseif data_has_only_instance_data(data)
        if isa(data[:instance_data], AbstractDict{Symbol,Any})
            load_time_series_data!(system, data) # substitute ts file paths with actual vectors of data

            data[:instance_data][:id] = Symbol(data[:instance_data][:id]) # Make sure the id is a Symbol
            data[:instance_data][:type] = check_and_convert_type(data) # Add the type to the instance data
            push!(system.input_data, data[:instance_data]) #Store the input data for later use

            if system.settings.Retrofitting
                make_retrofit_options(system, data) # Make retrofitting assets for assets with retrofit_options
            end

            # Hack to simplify EGS resources
            id_list = ["WA_Near", "WA_Deep", "OR_Near", "ID_Near", "ID_Deep", "MT_Deep", "WY_Near", "WY_Deep", "AZ_Near", "AZ_Deep", "CO_Near", "CO_Deep", "CA_NearField_5_5_289_c244", "CA_NearField_3_5_228_c239", "CA_NearField_4_5_253_c242","CA_Deep_5_5_278_c52","CA_Deep_4_5_243_c47" ,"CA_Deep_3_5_214_c41", "CA_Deep_5_5_269_c53", "CA_NearField_2_5_203_c236", "CA_NearField_5_5_268_c245", "CA_Deep_6_5_298_c56", "CA_Deep_5_5_263_c54", "NV_NearField_2_5_200_c249", "NV_NearField_3_5_216_c252", "NV_Deep_3_5_211_c61","NV_Deep_6_5_296_c76", "NV_Deep_6_5_290_c77", "NV_Deep_5_5_254_c73", "UT_Deep_4_5_229_c146", "UT_Deep_5_5_256_c152","UT_Deep_6_5_291_c156", "NM_Deep_6_5_294_c196", "NM_Deep_6_5_284_c197", "NM_Deep_5_5_250_c192", "NM_Deep_4_5_219_c186", "NM_Deep_6_5_274_c198", "NM_Deep_5_5_236_c193", "OR_Deep_5_5_282_c31", "OR_Deep_5_5_268_c32", "OR_Deep_6_5_296_c36","OR_Deep_4_5_229_c27",
            "UT_NearField_2_5_250_c263", "UT_NearField_3_5_286_c266", "UT_NearField_2_5_225_c264","UT_NearField_4_5_288_c269","UT_NearField_3_5_239_c267","UT_NearField_5_5_288_c272","UT_Deep_5_5_282_c151","UT_NearField_2_5_200_c265","UT_NearField_4_5_239_c270", "NV_Deep_4_5_249_c66", "NV_NearField_5_5_283_c257", "NV_Deep_5_5_273_c71", "NV_Deep_5_5_265_c72","CA_Deep_5_5_290_c51"]
            
            # Skip if any of the id_list strings appear as a substring in the instance id
            if any(occursin(s, string(data[:instance_data][:id])) for s in id_list)
                # @info("Skipping $(data[:instance_data][:id])")
            else
                add!(system, make(data[:instance_data][:type], data[:instance_data], system))    
            end
            
            # add!(system, make(data[:instance_data][:type], data[:instance_data], system))

        elseif isa(data[:instance_data], AbstractVector{<:AbstractDict{Symbol,Any}})
            load!(system, expand_instances(data))
        else
            throw(ArgumentError("Instance data is not a dictionary or vector of dictionaries"))
        end

    elseif data_is_filepath(data)
        # println("Loading data from file")
        load!(system, data[:path])

    else
        for (key, value) in data
            # println("Loading $key")
            load!(system, value)
        end

    end

    return nothing
end

# Load a vector of instances of assets, locations, etc. into a System
function load!(system::System, data::AbstractVector{<:AbstractDict{Symbol,Any}})::Nothing
    for instance in data
        load!(system, instance)
    end
    return nothing
end

function load!(system::System, data)::Nothing
    # This is for unhandled types, which will most likely be empty Vector
    # or bad inputs
    @debug("Bad or empty input to load!(). The input data was:\n$data")
    return nothing
end

function merge_global_data(data::AbstractDict{Symbol,Any})
    instances = Vector{Dict{Symbol,Any}}()
    type = data[:type]
    for (instance_idx, instance_data) in enumerate(data[:instance_data])
        instance_data = recursive_merge(deepcopy(data[:global_data]), instance_data)
        # haskey(instance_data, :id) ? instance_id = Symbol(instance_data[:id]) : instance_id = default_asset_name(instance_idx, a_name)
        # instance_data[:id], _ = make_asset_id(instance_id, asset_data)
        # asset_data[instance_data[:id]] = make_asset(a_type, instance_data, time_data, nodes)
        push!(instances, Dict{Symbol,Any}(:type => type, :instance_data => instance_data))
    end
    return instances
end

function expand_instances(data::AbstractDict{Symbol,Any})
    instances = Vector{Dict{Symbol,Any}}()
    type = data[:type]
    for instance_data in data[:instance_data]
        push!(instances, Dict{Symbol,Any}(:type => type, :instance_data => instance_data))
    end
    return instances
end

###### ###### ###### ###### ###### ######
# Checks on the kind of data
###### ###### ###### ###### ###### ######

function check_and_convert_type(data::AbstractDict{Symbol,Any}, m::Module = MacroEnergy)
    if !haskey(data, :type)
        throw(ArgumentError("Instance data requires a :type field"))
    end
    type = Symbol(data[:type])
    if haskey(commodity_types(m), type)
        return commodity_types(m)[type]
    end
    validate_type_attribute(type, m)
    return getfield(m, type)
end

function data_has_only_instance_data(data::AbstractDict{Symbol,Any})::Bool
    # Check that data has only :type and :instance_data fields
    # We could also check the types of the fields
    entries = collect(keys(data))
    if length(entries) == 2 && issetequal(entries, [:type, :instance_data])
        return true
    else
        return false
    end
end

function data_has_global_data(data::AbstractDict{Symbol,Any})::Bool
    # Check that data has only :type, :instance_data, :global_data fields
    entries = collect(keys(data))
    if length(entries) == 3 && issetequal(entries, [:type, :instance_data, :global_data])
        return true
    else
        return false
    end
end

function data_is_filepath(data::AbstractDict{Symbol,Any})::Bool
    entries = collect(keys(data))
    if length(entries) == 1 && issetequal(entries, [:path])
        return true
    else
        return false
    end
end

function data_is_system_data(data::AbstractDict{Symbol,Any})::Bool
    # Check if it contains any special fields
    entries = collect(keys(data))
    special_keys = [:settings]
    for key in special_keys
        if key in entries
            return true
        end
    end
    return false
end