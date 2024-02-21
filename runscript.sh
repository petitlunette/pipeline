#!/bin/bash

# Path to the configuration file
config_file="config.ini"

# Function to read a value from the configuration file
get_config_value() {
    awk -F "=" -v section="$1" -v key="$2" '$0 ~ "\\["section"\\]" {flag=1; next} /\\[.*\\]/ {flag=0} flag && $1 ~ key {print $2; exit}' "$config_file" | tr -d ' '
}

# List of programs to check

default_programs=("Dorado" "Nanoplot" "Flye" "Meryl" "Merqury" "Medaka" "VALET" "Metawrap" "Kraken2")
optional_programs=("Racon")
not_found_programs=()
declare -A program_paths

for program in "${default_programs[@]}" "${optional_programs[@]}"; do
    # Try to read program path from the configuration file first
    program_path=$(get_config_value "$program" "path")
    config_path_used=false

    if [ -n "$program_path" ]; then
        config_path_used=true
    else
        # Define standard locations for the program
        standard_paths=("/usr/local/bin/$program" "/usr/bin/$program")
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
    # Store the path in the associative array
        program_paths[$program]="$program_path"
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
read INPUT_PATH

# Check if the file exists
if [ -d "$INPUT_PATH" ]; then
    echo "Directory found at: $INPUT_PATH"
else
    echo "Directory not found at: $INPUT_PATH. Please check the path and try again."
fi

#Prompt the user for the input file type
echo "Which input file type are you using? (pod5/fast5)"
read FILE_TYPE


# Define file paths
VIRTUAL_ENV_PATH=$(get_config_value "Medaka" "medaka_env_path")
DATA_OUTPUT_PATH=$(get_config_value "Data" "output_data_dir")
PYTHON_PATH=$(which python || which python3)

# Create directories for each tool output within the virtual environment
mkdir -p $DATA_OUTPUT_PATH/dorado
mkdir -p $DATA_OUTPUT_PATH/nanoplot
mkdir -p $DATA_OUTPUT_PATH/flye
mkdir -p $DATA_OUTPUT_PATH/meryl
mkdir -p $DATA_OUTPUT_PATH/merqury
mkdir -p $DATA_OUTPUT_PATH/medaka

 # Ask user if they want to run Dorado for base calling
read -p "Do you want to run Dorado for base calling? (yes/no): " run_dorado
if [[ "$run_dorado" == "yes" ]]; then
    echo "Running Dorado..."
    cd $DATA_OUTPUT_PATH/dorado
    export PATH=${program_paths[Dorado]}:$PATH
    DORADO_MODEL=$(get_config_value "Dorado" "default_model")
    dorado download --model $DORADO_MODEL
    dorado basecaller $DORADO_MODEL $INPUT_PATH/*$FILE_TYPE/ > calls.fastq.gz
fi

echo "Running NanoPlot..."
export PATH=${program_paths[Nanoplot]}:$PATH
NanoPlot --fastq calls.fastq.gz -o $DATA_OUTPUT_PATH/nanoplot
cat $DATA_OUTPUT_PATH/nanoplot/NanoStats.txt 
read -p "Is the quality of the data sufficient to run the pipeline? (yes/no): " run_pipeline
if [[ "$run_pipeline" == "no" ]]; then
    exit
fi
if [[ "$run_pipeline" == "yes" ]]; then
    echo "Running Flye ..."
    FLYE_ITERATIONS=$(get_config_value "Flye" "default_iterations")
    FLYE_QUALITY=$(get_config_value "Flye" "default_read_quality")
    if [[ "$run_dorado" == "yes" ]]; then
        ${PYTHON_PATH} ${program_paths[Flye]} --nano-hq $DATA_OUTPUT_PATH/dorado/calls.fastq.gz --out-dir $DATA_OUTPUT_PATH/flye --iterations $FLYE_ITERATIONS --meta
    else
        ${PYTHON_PATH} ${program_paths[Flye]} --nano-hq $INPUT_PATH/calls.fastq.gz --out-dir $DATA_OUTPUT_PATH/flye --iterations $FLYE_ITERATIONS --meta
    fi
    echo "Running Meryl..."
    cd $DATA_OUTPUT_PATH/meryl
    MERYL_KMERS=$(get_config_value "Meryl" "default_kmers")
    export PATH=${program_paths[Meryl]}:$PATH
    meryl count k=21 $DATA_OUTPUT_PATH/flye/assembly.fasta output asmDB.k21.meryl
    
    

    



