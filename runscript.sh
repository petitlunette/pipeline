#!/bin/bash

# Path to the configuration file
config_file="config.ini"

# Function to read a value from the configuration file
get_config_value() {
    awk -F "=" -v section="$1" -v key="$2" '$0 ~ "\\["section"\\]" {flag=1; next} /\\[.*\\]/ {flag=0} flag && $1 ~ key {print $2; exit}' "$config_file" | tr -d ' '
}


#Define file path
output_data_dir=$(get_config_value "Data" "output_data_dir")
DATA_OUTPUT_PATH=${output_data_dir/CURRENT_DIR/$(pwd)}
mkdir -p "$DATA_OUTPUT_PATH"

echo "Starting the pipeline. If not using defaults, define paths and program options in the config file. Checkpoints are used to skip completed steps. "
echo "Note: If you wish to rerun the entire pipeline or specific steps, please delete the '.<step_name>_done' files from '$DATA_OUTPUT_PATH'."
echo "To delete all checkpoint files and restart, run: 'rm $DATA_OUTPUT_PATH/.*_done'"
echo "Using output data directory: $DATA_OUTPUT_PATH"


# List of programs to check
declare -A program_paths
declare -a not_found_default_programs
declare -a not_found_optional_programs
default_programs=("Dorado" "Nanoplot" "Flye" "Meryl" "Merqury" "Medaka" "Metawrap" "Kraken2")
optional_programs=("Racon" "VALET")

# Function to check program paths
check_programs() {
    local program_list=("${!1}")
    local program_type="$2"
    for program in "${program_list[@]}"; do
        local program_path=""
        # Check standard locations first
        if [ -x "/usr/local/bin/$program" ]; then
            program_path="/usr/local/bin/$program"
        elif [ -x "/usr/bin/$program" ]; then
            program_path="/usr/bin/$program"
        else
            # If not found in standard locations, check the configuration file
            program_path=$(get_config_value "$program" "path")
        fi

        if [ -n "$program_path" ]; then
            program_paths[$program]="$program_path"
            echo "Using $program at: $program_path"
        else
            if [ "$program_type" == "default" ]; then
                not_found_default_programs+=("$program")
            else
                not_found_optional_programs+=("$program")
                echo "Optional program $program not found. It will be skipped."
            fi
        fi
    done
}

# Check default and optional programs
check_programs default_programs[@] default
check_programs optional_programs[@] optional

# Handle missing default programs
if [ ${#not_found_default_programs[@]} -ne 0 ]; then
    echo "The following default programs were not found: ${not_found_default_programs[*]}."
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
    exit
fi

#Prompt the user for the input file type
echo "Which input file type are you using? (pod5/fast5/fastq/fastq.gz)"
read FILE_TYPE


# Define file paths
VIRTUAL_ENV_PATH=$(get_config_value "Medaka" "medaka_env_path")
PYTHON_PATH=$(which python || which python3)

#Functions to create pipeline checkpoints 
create_checkpoint() {
    touch "$DATA_OUTPUT_PATH/.${1}_done"
}
check_for_checkpoint() {
    if [ -f "$DATA_OUTPUT_PATH/.${1}_done" ]; then
        echo "Checkpoint for ${1} found. Skipping..."
        return 0 # 0 indicates the checkpoint exists, so skip the step
    else
        return 1 # 1 indicates no checkpoint, so proceed with the step
    fi
}

# Create directories for each tool output within the virtual environment
mkdir -p $DATA_OUTPUT_PATH/dorado
mkdir -p $DATA_OUTPUT_PATH/nanoplot
mkdir -p $DATA_OUTPUT_PATH/flye
mkdir -p $DATA_OUTPUT_PATH/meryl
mkdir -p $DATA_OUTPUT_PATH/merqury
mkdir -p $DATA_OUTPUT_PATH/medaka
mkdir -p $DATA_OUTPUT_PATH/metawrap
mkdir -p $DATA_OUTPUT_PATH/kraken

 # Ask user if they want to run Dorado for base calling
read -p "Do you want to run Dorado for base calling? (yes/no): " run_dorado
if ! check_for_checkpoint "dorado"; then
    if [[ "$run_dorado" == "yes" ]]; then
        echo "Running Dorado..."
        cd $DATA_OUTPUT_PATH/dorado
        export PATH=${program_paths[Dorado]}:$PATH
        DORADO_MODEL=$(get_config_value "Dorado" "default_model")
        dorado download --model $DORADO_MODEL
        dorado basecaller $DORADO_MODEL $INPUT_PATH/*$FILE_TYPE/ > calls.fastq.gz
        create_checkpoint "dorado"
    fi
fi
echo "Running NanoPlot..."
export PATH=${program_paths[NanoPlot]}:$PATH
if [[ "$run_dorado" == "yes" ]]; then
    NanoPlot --fastq $DATA_OUTPUT_PATH/dorado/calls.fastq.gz -o $DATA_OUTPUT_PATH/nanoplot
else 
    NanoPlot --fastq $INPUT_PATH/*$FILE_TYPE/ -o $DATA_OUTPUT_PATH/nanoplot
fi
cat $DATA_OUTPUT_PATH/nanoplot/NanoStats.txt 
read -p "Is the quality of the data sufficient to run the pipeline? (yes/no): " run_pipeline
if [[ "$run_pipeline" == "no" ]]; then
    exit
else
    create_checkpoint "nanoplot"
fi
if [[ "$run_pipeline" == "yes" ]]; then
    if ! check_for_checkpoint "flye"; then
    echo "Running Flye ..."
    export PATH=${program_paths[Flye]}:$PATH
    FLYE_ITERATIONS=$(get_config_value "Flye" "default_iterations")
    FLYE_QUALITY=$(get_config_value "Flye" "default_read_quality")
    if [[ "$run_dorado" == "yes" ]]; then
        ${PYTHON_PATH} ${program_paths[Flye]} --nano-hq $DATA_OUTPUT_PATH/dorado/calls.fastq.gz --out-dir $DATA_OUTPUT_PATH/flye --iterations $FLYE_ITERATIONS --meta
    else
        ${PYTHON_PATH} ${program_paths[Flye]} --nano-hq $INPUT_PATH/*$FILE_TYPE/ --out-dir $DATA_OUTPUT_PATH/flye --iterations $FLYE_ITERATIONS --meta
    fi
create_checkpoint "flye"
fi
if ! check_for_checkpoint "meryl"; then
    echo "Running Meryl..."
    cd $DATA_OUTPUT_PATH/meryl
    export PATH=${program_paths[Meryl]}:$PATH
    MERYL_KMERS=$(get_config_value "Meryl" "default_kmers")
    meryl count k=$MERYL_KMERS $DATA_OUTPUT_PATH/flye/assembly.fasta output assembly.k$MERYL_KMERS.meryl
    create_checkpoint "meryl"
fi
if ! check_for_checkpoint "merqury"; then
    echo "Running Merqury..."
    cd $DATA_OUTPUT_PATH/merqury
    export PATH=${program_paths[Merqury]}:$PATH
    merqury.sh $DATA_OUTPUT_PATH/meryl/assembly.k$MERYL_KMERS.meryl $DATA_OUTPUT_PATH/flye/assembly.fasta merqury_output
    create_checkpoint "merqury"
fi
        #is it worth having another qc prompt check here before proceeding?
        #and then ask if running racon
        
if ! check_for_checkpoint "medaka"; then
    echo "Running Medaka..."
    source $VIRTUAL_ENV_PATH
    export PATH=${program_paths[Medaka]}:$PATH
    THREADS=$(get_config_value "Data" "threads")
    medaka_consensus -i $DATA_OUTPUT_PATH/dorado/calls.fastq.gz -d $DATA_OUTPUT_PATH/flye/assembly.fasta -o $DATA_OUTPUT_PATH/medaka -t $THREADS
    create_checkpoint "medaka"
    deactivate
fi  
        #VALET here
        
if ! check_for_checkpoint "metawrap"; then
    echo "Running MetaWrap..."
    eval "$(conda shell.bash hook)"
    export PATH=${program_paths[Metawrap]}:$PATH
    METAWRAP_ENV=$(get_config_value "Metawrap" "conda_env")
    if [ -z "$METAWRAP_ENV" ]; then
        echo "Conda environment name not found in config.ini. Please specify it under the [Environment] section."
        exit 1
    else
        echo "Using Conda environment: $METAWRAP_ENV"
    fi
    conda activate $METAWRAP_ENV
    if [[ "$run_dorado" == "yes" ]]; then
        binning -o $DATA_OUTPUT_PATH/metawrap -a $DATA_OUTPUT_PATH/medaka/consensus.fasta --metabat2 --maxbin2 --concoct --single-end $DATA_OUTPUT_PATH/dorado/calls.fastq.gz
    else
        binning -o $DATA_OUTPUT_PATH/metawrap -a $DATA_OUTPUT_PATH/medaka/consensus.fasta --metabat2 --maxbin2 --concoct --single-end $INPUT_PATH/*$FILE_TYPE/
    fi
    conda deactivate
    create_checkpoint "metawrap"
fi
    





echo "Pipeline execution completed. If you wish to rerun the pipeline or specific steps, remember to delete the '.<step_name>_done' checkpoint files from '$DATA_OUTPUT_PATH'."


    



