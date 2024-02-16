#!/bin/bash

# Path to the configuration file
config_file="config.ini"

# Function to read a value from the configuration file
get_config_value() {
    awk -F "=" -v section="$1" -v key="$2" '$0 ~ "\\["section"\\]" {flag=1; next} /\\[.*\\]/ {flag=0} flag && $1 ~ key {print $2; exit}' "$config_file" | tr -d ' '
}


# List of programs to check
default_programs=("Dorado" "Nanoplot" "MetaFlye" "Meryl" "Merqury" "Medaka" "VALET" "Metawrap" "Kraken2")
optional_programs=("Racon")
not_found_programs=()

for program in "${default_programs[@]}"; do
    # Try to read program path from the configuration file first
    program_path=$(get_config_value "$program" "path")
    config_path_used=false

    if [ -n "$program_path" ]; then
        config_path_used=true
    else
        # Define standard locations for the program
        standard_paths=("/usr/local/bin/$program" "/usr/bin/$program") # Add more paths as needed

        # Check standard locations
        for path in "${standard_paths[@]}"; do
            if [ -x "$path" ]; then
                program_path="$path"
                break
            fi
        done
    fi

    if [ -n "$program_path" ]; then
        # Echo the message only if the path was set using the configuration file
        if [ "$config_path_used" = true ]; then
            echo "Using $program at: $program_path (from configuration file)"
        fi
    else
        # Program not found, add to not found list
        not_found_programs+=("$program")
    fi
done

# Check if any program was not found
if [ ${not_found_programs[@]} -ne 0 ]; then
    echo "The following programs were not found: ${not_found_programs[@]}."
    echo "Please specify the paths to these programs in the configuration file and rerun the script."
    exit 1
fi


# Prompt the user for the input file location
echo "Please enter the path to your input data directory:"
read input_path

# Check if the file exists
if [ -d "$input_path" ]; then
    echo "Directory found at: $input_path"
else
    echo "Directory not found at: $input_path. Please check the path and try again."
fi

#Prompt the user for the input file type
echo "Which input file type are you using? (pod5/fast5)"
read file_type


# Create directories for each tool output within the virtual environment
mkdir -p $DATA_OUTPUT_PATH/dorado
mkdir -p $DATA_OUTPUT_PATH/NanoPlot
mkdir -p $DATA_OUTPUT_PATH/flye
mkdir -p $DATA_OUTPUT_PATH/meryl
mkdir -p $DATA_OUTPUT_PATH/merqury
mkdir -p $DATA_OUTPUT_PATH/medaka
