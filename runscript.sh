#!/bin/bash

# Path to the configuration file
config_file="$(pwd)/config.ini"

# Function to read a value from the configuration file
get_config_value() {
    awk -F "=" -v section="$1" -v key="$2" '$0 ~ "\\["section"\\]" {flag=1; next} /\\[.*\\]/ {flag=0} flag && $1 ~ key {print $2; exit}' "$config_file" | tr -d ' '
}


#Define file path
output_data_dir=$(get_config_value "Data" "output_data_dir")
DATA_OUTPUT_PATH=${output_data_dir/CURRENT_DIR/$(pwd)}
mkdir -p "$DATA_OUTPUT_PATH"

echo "Starting the pipeline. If not using defaults, define paths and program options in the config file. Checkpoints are used to skip completed steps. "
echo "Note: If you wish to rerun the entire pipeline or specific steps, please delete the '.<step_name>_done' files from '$DATA_OUTPUT_PATH'. with 'rm -f .<step>_done'"
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

if [[ "$INPUT_PATH" == */ ]]; then
    INPUT_PATH="${INPUT_PATH%?}"
fi

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
        return 0 
    else
        return 1
    fi
}

# Create directories for each tool output within the virtual environment
mkdir -p $DATA_OUTPUT_PATH/dorado
mkdir -p $DATA_OUTPUT_PATH/nanoplot
mkdir -p $DATA_OUTPUT_PATH/flye
mkdir -p $DATA_OUTPUT_PATH/meryl
mkdir -p $DATA_OUTPUT_PATH/merqury
mkdir -p $DATA_OUTPUT_PATH/medaka
mkdir -p $DATA_OUTPUT_PATH/valet
mkdir -p $DATA_OUTPUT_PATH/metawrap
mkdir -p $DATA_OUTPUT_PATH/kraken2

 # Ask user if they want to run Dorado for base calling
read -p "Do you want to run Dorado for base calling? (yes/no): " run_dorado
if ! check_for_checkpoint "dorado"; then
    if [[ "$run_dorado" == "yes" ]]; then
        echo "Running Dorado..."
        cd $DATA_OUTPUT_PATH/dorado
        export PATH=${program_paths[Dorado]}:$PATH
        DORADO_MODEL=$(get_config_value "Dorado" "default_model")
        dorado download --model $DORADO_MODEL
        dorado basecaller $DORADO_MODEL $INPUT_PATH/ > calls.fastq --emit-fastq
        create_checkpoint "dorado"
        echo "Dorado analysis completed. Results are stored in $DATA_OUTPUT_PATH/dorado"
    fi
fi
echo "Running NanoPlot..."
export PATH=${program_paths[NanoPlot]}:$PATH
THREADS=$(get_config_value "Data" "default_threads")
    if [[ "$run_dorado" == "yes" ]]; then
    ${program_paths[Nanoplot]} --fastq $DATA_OUTPUT_PATH/dorado/calls.fastq --outdir $DATA_OUTPUT_PATH/nanoplot --threads $THREADS
else
    ${program_paths[Nanoplot]} --fastq $INPUT_PATH/*$FILE_TYPE --outdir $DATA_OUTPUT_PATH/nanoplot --threads $THREADS
fi
cat $DATA_OUTPUT_PATH/nanoplot/NanoStats.txt 
echo "Nanoplot analysis completed. Results are stored in $DATA_OUTPUT_PATH/nanoplot"
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
    THREADS=$(get_config_value "Data" "default_threads")
    if [[ "$run_dorado" == "yes" ]]; then
        ${PYTHON_PATH} ${program_paths[Flye]} --nano-hq $DATA_OUTPUT_PATH/dorado/calls.fastq --out-dir $DATA_OUTPUT_PATH/flye --iterations $FLYE_ITERATIONS --meta --threads $THREADS
    else
        ${PYTHON_PATH} ${program_paths[Flye]} --nano-hq $INPUT_PATH/*$FILE_TYPE --out-dir $DATA_OUTPUT_PATH/flye --iterations $FLYE_ITERATIONS --meta --threads $THREADS
    fi
create_checkpoint "flye"
echo "Flye analysis completed. Results are stored in $DATA_OUTPUT_PATH/flye"
fi

if ! check_for_checkpoint "meryl"; then
    echo "Running Meryl..."
    cd $DATA_OUTPUT_PATH/meryl
    export PATH=${program_paths[Meryl]}:$PATH
    MERYL_KMERS=$(get_config_value "Meryl" "default_kmers")
    THREADS=$(get_config_value "Data" "default_threads")
    MEMORY=$(get_config_value "Data" "default_memory")
    meryl count k=$MERYL_KMERS $DATA_OUTPUT_PATH/flye/assembly.fasta output assembly.k$MERYL_KMERS.meryl threads=$THREADS memory=$MEMORY
    create_checkpoint "meryl"
    echo "Meryl analysis completed. Results are stored in $DATA_OUTPUT_PATH/meryl"
fi
if ! check_for_checkpoint "merqury"; then
    echo "Running Merqury..."
    cd $DATA_OUTPUT_PATH/merqury
    export PATH=${program_paths[Merqury]}:$PATH
    export MERQURY=${program_paths[Merqury]}
    merqury.sh $DATA_OUTPUT_PATH/meryl/assembly.k$MERYL_KMERS.meryl $DATA_OUTPUT_PATH/flye/assembly.fasta merqury_output
    create_checkpoint "merqury"
    echo "Merqury analysis completed. Results are stored in $DATA_OUTPUT_PATH/merqury"
fi
        
if ! check_for_checkpoint "medaka"; then
    echo "Running Medaka..."
    source $VIRTUAL_ENV_PATH
    export PATH=${program_paths[Medaka]}:$PATH
    THREADS=$(get_config_value "Data" "default_threads")
    THREADS=$(get_config_value "Medaka" "default_model")
    TEMP_FASTQ_PATH="$INPUT_PATH/temp"
    if [[ "$run_dorado" == "yes" ]]; then
        medaka_consensus -i $DATA_OUTPUT_PATH/dorado/calls.fastq -d $DATA_OUTPUT_PATH/flye/assembly.fasta -o $DATA_OUTPUT_PATH/medaka -t $THREADS
    elif [[ "$FILE_TYPE" == "fastq.gz" ]]; then
        mkdir -p "$TEMP_FASTQ_PATH"
        for gz in $INPUT_PATH/*.fastq.gz; do
            gzip -dkc "$gz" > "$TEMP_FASTQ_PATH/$(basename "${gz%.*}")"
        done
    	medaka_consensus -i $TEMP_FASTQ_PATH -d $DATA_OUTPUT_PATH/flye/assembly.fasta -o $DATA_OUTPUT_PATH/medaka -t $THREADS -m $MODEL
    else
        medaka_consensus -i $INPUT_PATH -d $DATA_OUTPUT_PATH/flye/assembly.fasta -o $DATA_OUTPUT_PATH/medaka -t $THREADS -m $MODEL
    fi
    create_checkpoint "medaka"
    echo "Medaka analysis completed. Results are stored in $DATA_OUTPUT_PATH/medaka"
    deactivate
fi 
        
if ! check_for_checkpoint "valet"; then
    echo "Running VALET for misassembly detection..."
    export PATH=${program_paths[Valet]}:$PATH
    THREADS=$(get_config_value "Data" "default_threads")
    BASE_CMD="${PYTHON_PATH} ${program_paths[VALET]}/valet.py -a $DATA_OUTPUT_PATH/medaka/consensus.fasta -r"
    FASTQ_FILES=$(find "$INPUT_PATH" -type f -name "*.fastq" | paste -sd "," -)
    TEMP_FASTQ_FILES=$(find "$TEMP_FASTQ_PATH" -type f -name "*.fastq" | paste -sd "," -)
    FASTQ_CMD="$BASE_CMD $FASTQ_FILES"
    TEMP_FASTQ_CMD="$BASE_CMD $TEMP_FASTQ_FILES"
    if [[ "$run_dorado" == "yes" ]]; then
        $BASE_CMD $DATA_OUTPUT_PATH/dorado/calls.fastq  -o $DATA_OUTPUT_PATH/valet -p $THREADS
    elif [[ "$FILE_TYPE" == "fastq.gz" ]]; then
        $TEMP_FASTQ_CMD -o $DATA_OUTPUT_PATH/valet -p $THREADS
    else
        $FASTQ_CMD -o $DATA_OUTPUT_PATH/valet -p $THREADS
    fi
    echo "VALET analysis completed. Results are stored in $DATA_OUTPUT_PATH/valet"
    create_checkpoint "valet"
fi

if ! check_for_checkpoint "metawrap"; then
    echo "Running MetaWrap..."
    eval "$(conda shell.bash hook)"
    METAWRAP_ENV=$(get_config_value "Metawrap" "conda_env")
    if [ -z "$METAWRAP_ENV" ]; then
        echo "Conda environment name not found in config.ini. Please specify it under the [Metawrap] section."
        exit 1
    else
        echo "Using Conda environment: $METAWRAP_ENV"
    fi
    conda activate $METAWRAP_ENV
    export PATH=${program_paths[Metawrap]}:$PATH
    THREADS=$(get_config_value "Data" "default_threads")
    TEMP_FASTQ_PATH="$INPUT_PATH/temp"
    META_FASTQ_FILES=$(find "$INPUT_PATH" -type f -name "*.fastq" | paste -sd " " -)
    META_TEMP_FASTQ_FILES=$(find "$TEMP_FASTQ_PATH" -type f -name "*.fastq" | paste -sd " " -)
    META_BASE_CMD="metawrap binning -o $DATA_OUTPUT_PATH/metawrap -a $DATA_OUTPUT_PATH/medaka/consensus.fasta --maxbin2 --concoct --single-end"
    META_FASTQ_CMD="$META_BASE_CMD $META_FASTQ_FILES"
    META_TEMP_FASTQ_CMD="$META_BASE_CMD $META_TEMP_FASTQ_FILES"
    if [[ "$run_dorado" == "yes" ]]; then
        $META_BASE_CMD $DATA_OUTPUT_PATH/dorado/calls.fastq.gz -t $THREADS
    elif [[ "$FILE_TYPE" == "fastq.gz" ]]; then
        $META_TEMP_FASTQ_CMD $META_TEMP_FASTQ_FILES -t $THREADS
    else
        $META_FASTQ_CMD $META_FASTQ_FILES -t $THREADS
    fi
    metawrap bin_refinement -o $DATA_OUTPUT_PATH/metawrap/final_bins -A $DATA_OUTPUT_PATH/metawrap/concoct_bins -B $DATA_OUTPUT_PATH/metawrap/maxbin2_bins -t $THREADS
    conda deactivate
    create_checkpoint "metawrap"
    echo "Metawrap analysis completed. Results are stored in $DATA_OUTPUT_PATH/metawrap"
fi
fi
    
#Kraken2 

if ! check_for_checkpoint "kraken2"; then
    DBNAME=$(get_config_value "Kraken2" "dbname")
    THREADS=$(get_config_value "Data" "default_threads")
    database_setup_success=false
    if [[ -z "$DBNAME" ]]; then
        read -p "No Kraken2 database location found in the config. Do you have an existing Kraken2 database? (yes/no): " has_kraken_db
        if [[ "$has_kraken_db" == "yes" ]]; then
            read -p "Enter the location of your existing Kraken2 database: " DBNAME
	    database_setup_success=true
        else
            read -p "Enter a location for your new Kraken2 database: " DBNAME
            echo "Creating and building new Kraken2 database at $DBNAME..."
	    mkdir -p "$DBNAME"
            if kraken2-build --standard --db "$DBNAME"; then
	    	database_setup_success=true
      	    else
                echo "Standard database build failed. Attempting to download prebuilt database..."
                wget -O "$DBNAME/k2_standard_20240112.tar.gz" https://genome-idx.s3.amazonaws.com/kraken/k2_standard_20240112.tar.gz
		if [ $? -eq 0 ]; then
                    echo "Extracting database..."
		    tar -xzf "$DBNAME/k2_standard_20240112.tar.gz" -C "$DBNAME" --strip-components=1 
		    rm "$DBNAME/k2_standard_20240112.tar.gz"
      		    database_setup_success=true
                else
                    echo "Failed to download the prebuilt database. Please check your internet connection or the URL and try again."
                    fi
                fi
	    fi 
	    if [[ "$database_setup_success" == true ]]; then
                echo "Database $DBNAME setup complete."
                sed -i "/^\[Kraken2\]/,/^\[/ {/^dbname=/ s|=.*|=$DBNAME|}" "$config_file"
                echo "Kraken2 database location updated in config: $DBNAME"
            else
	    	echo "Kraken2 database setup failed. Exiting."
      		exit 1
    	    fi
        else
   	    echo "Found Kraken2 database location in config: $DBNAME"
	    database_setup_success=true
        fi
	if [[ "$database_setup_success" == true ]]; then
            echo "Proceeding with Kraken2 analysis..."
	    EXCLUDE_DIRS=("concoct_bins" "figures" "maxbin2_bins" "work_files")
 	    UNIQUE_DIRS=$(find "$DATA_OUTPUT_PATH/metawrap/final_bins" -mindepth 1 -maxdepth 1 -type d | grep -vE "$(printf "|%s" "${EXCLUDE_DIRS[@]}" | sed 's/^|//')")
    	    if [ -z "$UNIQUE_DIRS" ]; then
           	echo "No unique directories found."
            	exit 1
   	    fi
    	    echo "Unique directories found: $UNIQUE_DIRS"
    	    while read -r UNIQUE_DIR; do
       	    	if [ ! -z "$UNIQUE_DIR" ]; then
            	    echo "Processing directory: $UNIQUE_DIR"
            	    FASTA_FILES=$(find "$UNIQUE_DIR" -type f -name "*.fa")
            	    if [ -z "$FASTA_FILES" ]; then
                    	echo "No FASTA files found in $UNIQUE_DIR."
                    	continue
            	    fi
            	    while read -r FASTA_FILE; do
                    	echo "Running Kraken2 analysis on $FASTA_FILE..."
                    	basename_fasta=$(basename "$FASTA_FILE" .fa)
                    	kraken2 --db "$DBNAME" "$FASTA_FILE" --output "$DATA_OUTPUT_PATH/kraken2/${basename_fasta}_kraken2_output.txt" --report "$DATA_OUTPUT_PATH/kraken2/${basename_fasta}_kraken2_report.txt" --threads $THREADS 
            	    done <<< "$FASTA_FILES"
            	fi
    	    	done <<< "$UNIQUE_DIRS"
    	    else
            	echo "Unable to proceed without a valid Kraken2 database setup."
            exit 1
    	fi
    	create_checkpoint "kraken2"
    fi


echo "Pipeline execution completed. If you wish to rerun the pipeline or specific steps, remember to delete the '.<step_name>_done' checkpoint files from '$DATA_OUTPUT_PATH'."


    
