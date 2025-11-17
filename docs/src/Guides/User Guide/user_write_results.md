# Writing Results to Files

Currently, Macro supports the following types of outputs:

- [Capacity Results](@ref): final capacity, new capacity and retired capacity for each technology.
- [Costs](@ref): fixed, variable and total system costs.
- [Flow Results](@ref): flow for each commodity through each edge in the system.
- [Combined Results](@ref): all results (capacity, costs, flows, non-served demand, storage level) in a single file.

For detailed information about output formats and layouts, please refer to the [Output Format](@ref) and [Output Files Layout](@ref) sections below.

!!! note "Output Files Location"
    By default, output files are written to a `results` directory created in the same location as your input data. For more details about output file locations, see the [Output Files Location](@ref) section below.

## Capacity Results
To export system-level capacity results to a file, users can use the [`write_capacity`](@ref) function:

```julia
write_capacity("capacity.csv", system)
```

This function exports capacity results for all commodities and asset types defined in your case inputs. 

You can filter the results by commodity, asset type, or both using the `commodity` and `asset_type` parameters:

```julia
# Filter results by commodity
write_capacity("capacity.csv", system, commodity="Electricity")
# Filter results by asset type
write_capacity("capacity.csv", system, asset_type="ThermalPower")
# Filter results by commodity and asset type
write_capacity("capacity.csv", system, commodity="Electricity", asset_type=["VRE", "Battery"])
```

The `*` wildcard character enables pattern matching for asset types. For example, the following command exports results for all asset types beginning with `ThermalPower` (e.g., `ThermalPower`, `ThermalPowerCCS`):

```julia
# Filter using wildcard matching for asset types
write_capacity("capacity.csv", system, commodity="Electricity", asset_type="ThermalPower*")
```

Similarly, you can use wildcard matching for commodities:

```julia
# Filter using wildcard matching for commodities
write_capacity("capacity.csv", system, commodity="CO2*")
```

!!! note "Output Layout"
    Results are written in *long* format by default. To use *wide* format, configure the `OutputLayout: {"Capacity": "wide"}` setting in your Macro settings JSON file (see [Output Files Layout](@ref) for details).

## Costs

Export system-wide cost results using the [`write_costs`](@ref) function:

```julia
write_costs("costs.csv", system, model)
```

Note that the `write_costs` function requires both the `system` and `model` arguments, unlike the `write_capacity` function.

!!! note "Output Layout"
    Results are written in *long* format by default. To use *wide* format, configure the `OutputLayout: {"Costs": "wide"}` setting in your Macro settings JSON file (see [Output Files Layout](@ref) for details).

## Flow Results

Export system-level flow results using the [`write_flow`](@ref) function:

```julia
write_flow("flows.csv", system)
```

Filter results by commodity, asset type, or both using the `commodity` and `asset_type` parameters:

```julia
# Filter by commodity
write_flow("flows.csv", system, commodity="Electricity")

# Filter by asset type using parameter-free matching
write_flow("flows.csv", system, asset_type="ThermalPower")

# Filter by asset type using wildcard matching
write_flow("flows.csv", system, asset_type="ThermalPower*")
```

!!! note "Output Layout"
    Results are written in *long* format by default. To use *wide* format, configure the `OutputLayout: {"Flow": "wide"}` setting in your Macro settings JSON file (see [Output Files Layout](@ref) for details).

## Combined Results

Export all results at once using the [`write_results`](@ref) function:

```julia
write_results(file_path, system, model, settings, ext=".csv.gz") # Creates multiple .csv.gz files
write_results(file_path, system, model, settings, ext=".parquet") # Creates multiple .parquet files
```

!!! note "Multiple Output Files"
    This function creates multiple files, one for each result type:
    - `file_path_capacity.ext` - Capacity results
    - `file_path_flow.ext` - Flow results  
    - `file_path_non_served_demand.ext` - Non-served demand
    - `file_path_storage_level.ext` - Storage levels
    - `file_path_discounted_costs.ext` - Discounted costs
    - `file_path_undiscounted_costs.ext` - Undiscounted costs

## Writing Case Settings

To export case and system settings to a JSON file, use the [`write_settings`](@ref) function:

```julia
write_settings(case, "output/settings.json")
```

This function automatically writes:
- Case-level settings
- System-level settings for all systems in the case

The settings file is useful for:
- Documentation and reproducibility
- Sharing configuration with other users
- Debugging and troubleshooting

!!! note "Automatic Settings Writing"
    The `write_settings` function is automatically called when using the main output writing functions (`write_outputs`) for different solution algorithms (Monolithic, Myopic, Benders).

## Output Format

Macro supports multiple output formats to suit different needs:

- **CSV**: Comma-separated values
  - Ideal for small datasets and human-readable output
  - Directly compatible with spreadsheet software
  - Less efficient for large datasets
- **CSV.GZ**: Compressed CSV
  - Balances readability and file size
  - Reduces storage requirements while maintaining CSV format
  - Requires decompression for reading
- **Parquet**: Column-based data store
  - Optimal for large datasets
  - Superior compression and faster read/write operations
  - Requires specialized tools for reading

The output format is determined by the file extension. For example, to export results in Parquet format:

```julia
write_results("results.parquet", system, model, settings)
```

## Output Files Layout

By default, all results are written in *long* format for optimal storage efficiency and performance, particularly for large systems. The *wide* format is also available for easier reading and visualization.

Configure the output layout using the `OutputLayout` setting in your Macro settings JSON file:

```json
{
  "OutputLayout": "wide"
}
```

or

```json
{
  "OutputLayout": {
    "Capacity": "wide",
    "Costs": "long",
    "Flow": "long"
  }
}
```

Available options:
- `"OutputLayout": "long"` (applies to all outputs)
- `"OutputLayout": "wide"` (applies to all outputs)
- `"OutputLayout": {"Capacity": "wide", "Costs": "long", "Flow": "long"}` (individual layout settings)

## Output Files Location

Macro provides two settings to control output file locations:
- `OutputDir`: Specifies the output directory name
- `OverwriteResults`: Controls whether to overwrite existing files

For example:

```json
{
  "OutputDir": "results",
  "OverwriteResults": true
}
```

Users can obtain the output directory path programmatically using the [`create_output_path`](@ref) function:

```julia
output_path = create_output_path(system)
```

and then pass this path to the write functions:

```julia
write_capacity(joinpath(output_path, "capacity.csv"), system)
```

By default, the `create_output_path` function creates a `results` directory in the same location as your input data (i.e., the directory containing `system_data.json`). For more information about the input folder structure, refer to the [Creating a new System](@ref) guide.

If `OverwriteResults` is `true`, existing files will be overwritten. Otherwise, the function appends a number to the directory name to prevent overwriting.

Users can specify a custom base path for the output directory:

```julia
output_path = create_output_path(system, "path/to/output")
write_capacity(joinpath(output_path, "capacity.csv"), system) # Creates /path/to/output/results/capacity.csv
```

In this case, the function creates a directory named according to the `OutputDir` setting (e.g., `results`) within your specified path (e.g., `path/to/output/results`).
