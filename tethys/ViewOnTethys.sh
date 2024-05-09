#!/bin/bash
# ANSI color codes
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
RESET='\e[0m'

# GEOSERVER FUNCTIONS

# run the geoserver docker container
_run_geoserver(){
    docker run -it --rm -d -p $GEOSERVER_PORT_HOST:$GEOSERVER_PORT_CONTAINER \
    --platform $PLATFORM \
    --env CORS_ENABLED=true \
    --env SKIP_DEMO_DATA=true \
    --network $DOCKER_NETWORK \
    --name $GEOSERVER_CONTAINER_NAME \
    $GEOSERVER_IMAGE_NAME 
    # > /dev/null 2>&1
}

_check_for_existing_geoserver_image() {
    printf "${YELLOW}Select an option (type a number): ${RESET}\n"
    options=("Run GeoServer using existing local docker image" "Run GeoServer after updating to latest docker image" "Exit")
    select option in "${options[@]}"; do
        case $option in
            "Run GeoServer using existing local docker image")
                printf "${GREEN}Using local image of GeoServer${RESET}\n"
                return 0
                ;;
            "Run GeoServer after updating to latest docker image")
                printf "${GREEN}Pulling container...${RESET}\n"
                if ! docker pull "$GEOSERVER_IMAGE_NAME"; then
                    printf "${RED}Failed to pull Docker image: $GEOSERVER_IMAGE_NAME${RESET}\n" >&2
                    return 1
                else
                    printf "${GREEN}Successfully updated GeoServer image.${RESET}\n"
                fi
                return 0
                ;;
            "Exit")
                printf "${CYAN}Have a nice day!${RESET}\n"
                _tear_down
                exit 0
                ;;
            *)
                printf "${RED}Invalid option $REPLY. Please type 1 to continue with existing local image, 2 to update and run, or 3 to exit.${RESET}\n"
                ;;
        esac
    done
}

_tear_down_geoserver(){
    if [ "$(docker ps -aq -f name=$GEOSERVER_CONTAINER_NAME)" ]; then
        docker stop $GEOSERVER_CONTAINER_NAME > /dev/null 2>&1 
        rm -rf $DATA_FOLDER_PATH/tethys/geoserver_data
    fi
}

# HELPER FUNCTIONS
# Function to automatically select file if only one is found
_auto_select_file() {
  local files=($1)
  if [ "${#files[@]}" -eq 1 ]; then
    echo "${files[0]}"
  else
    echo ""
  fi
}

# Check if the config file exists and read from it
_check_and_read_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        local last_path=$(cat "$config_file")
        printf "Last used data directory path: %s\n" "$last_path"
        read -erp "Do you want to use the same path? (Y/n): " use_last_path
        if [[ "$use_last_path" != [Nn]* ]]; then
            DATA_FOLDER_PATH="$last_path"
        else
            read -erp "Enter your input data directory path (use absolute path): " HOST_DATA_PATH
        fi
    else
        read -erp "Enter your input data directory path (use absolute path): " HOST_DATA_PATH
    fi
}
_execute_command() {
  "$@"
  local status=$?
  if [ $status -ne 0 ]; then
    echo -e "${RED}Error executing command: $1${RESET}"
    _tear_down
    exit 1
  fi
  return $status
}

_tear_down(){
    _tear_down_tethys
    _tear_down_geoserver
    docker network rm $DOCKER_NETWORK > /dev/null 2>&1
}

_run_containers(){
    _run_tethys
    echo -e "${GREEN}Setup GeoServer image...${RESET}"
    _check_for_existing_geoserver_image
    _run_geoserver
    _wait_container $TETHYS_CONTAINER_NAME
    _wait_container $GEOSERVER_CONTAINER_NAME
}

# Wait for a Docker container to become healthy or unhealthy
_wait_container() {
    local container_name=$1
    local container_health_status
    local max_attempts=300  # Set a maximum number of attempts (300 attempts * 2 seconds = 600 seconds max wait time)
    local attempt_counter=0

    printf "${MAGENTA}Waiting for container: $container_name to start, this can take a couple of minutes...${RESET}\n"

    until [[ "$container_health_status" == "healthy" || "$container_health_status" == "unhealthy" ]]; do
        if [[ $attempt_counter -eq $max_attempts ]]; then
            printf "${RED}Timeout waiting for container $container_name to become stable.${RESET}\n" >&2
            return 1
        fi

        # Update the health status
        if ! container_health_status=$(docker inspect -f '{{.State.Health.Status}}' "$container_name" 2>/dev/null); then
            printf "${RED}Failed to get health status for container $container_name. Ensure container exists and has a health check.${RESET}\n" >&2
            return 1
        fi

        if [[ -z "$container_health_status" ]]; then
            printf "${RED}No health status available for container $container_name. Ensure the container has a health check configured.${RESET}\n" >&2
            return 1
        fi

        ((attempt_counter++))
        sleep 2  # Adjusted sleep time to 2 seconds to reduce system load
    done

    printf "${MAGENTA}Container $container_name is now $container_health_status.${RESET}\n"
    return 0
}

_pause_script_execution() {
    while true; do
        printf "${YELLOW}Press q to exit the visualization (default: q/Q):${RESET}\n"
        read -r exit_choice

        if [[ "$exit_choice" =~ ^[qQ]$ ]]; then
            printf "${RED}Cleaning up Tethys ...${RESET}\n"
            _tear_down
            exit 0
        else
            printf "${RED}Invalid input. Please press 'q' or 'Q' to exit.${RESET}\n"
        fi
    done
}

# Function to handle the SIGINT (Ctrl-C)
handle_sigint() {
    echo -e "${RED}Cleaning up . . .${RESET}"
    _tear_down
    exit 1
}

check_last_path() {
    if [[ -z "$1" ]]; then
        _check_and_read_config "$CONFIG_FILE"
        
    else
        DATA_FOLDER_PATH="$1"
    fi
    # Finding files
    HYDRO_FABRIC=$(find "$DATA_FOLDER_PATH/config" -name "*datastream*.gpkg")
    CATCHMENT_FILE=$(find "$DATA_FOLDER_PATH/config" -name "*catchments*.geojson")
    NEXUS_FILE=$(find "$DATA_FOLDER_PATH/config" -name "*nexus*.geojson")
}

# TETHYS FUNCTIONS 
#create the docker network to communicate between tethys and geoserver
_create_tethys_docker_network(){
    docker network create -d bridge tethys-network > /dev/null 2>&1
}

# Link the data to the app workspace
_link_data_to_app_workspace(){
    _execute_command docker exec -it $TETHYS_CONTAINER_NAME sh -c \
        "mkdir -p $APP_WORKSPACE_PATH && \
        ln -s $TETHYS_PERSIST_PATH/ngen-data $APP_WORKSPACE_PATH/ngen-data"
}

_convert_gpkg_to_geojson() {
    local python_bin_path="$1"
    local path_script="$2"
    local gpkg_file="$3"
    local layer_name="$4"
    local geojson_file="$5"

    _execute_command docker exec -it \
        $TETHYS_CONTAINER_NAME \
        $python_bin_path \
        $path_script \
        --convert_to_geojson \
        --gpkg_path $gpkg_file \
        --layer_name $layer_name \
        --output_path $geojson_file
}

_publish_gpkg_layer_to_geoserver() {

    local python_bin_path="/opt/conda/envs/tethys/bin/python"
    local path_script="/usr/lib/tethys/apps/ngiab/cli/convert_geom.py"
    local catchment_gpkg_layer="divides"
    local gpkg_file_path="$APP_WORKSPACE_PATH/ngen-data/config/datastream.gpkg"
    local catchment_geojson_path="$APP_WORKSPACE_PATH/ngen-data/config/catchments.geojson"
    local shapefile_path="$APP_WORKSPACE_PATH/ngen-data/config/catchments"
    local geoserver_port="$GEOSERVER_PORT_CONTAINER"
    
    _execute_command docker exec -it \
        $TETHYS_CONTAINER_NAME \
        $python_bin_path \
        $path_script \
        --publish \
        --gpkg_path $gpkg_file_path \
        --layer_name $catchment_gpkg_layer \
        --shp_path "$shapefile_path" \
        --geoserver_host $GEOSERVER_CONTAINER_NAME \
        --geoserver_port $geoserver_port \
        --geoserver_username admin \
        --geoserver_password geoserver
}

_publish_geojson_layer_to_geoserver() {

    local python_bin_path="/opt/conda/envs/tethys/bin/python"
    local path_script="/usr/lib/tethys/apps/ngiab/cli/convert_geom.py"
    local geojson_path="$APP_WORKSPACE_PATH/ngen-data/config/catchments.geojson"
    local shapefile_path="$APP_WORKSPACE_PATH/ngen-data/config/catchments"
    local geoserver_port="$GEOSERVER_PORT_CONTAINER"
    
    _execute_command docker exec -it \
        $TETHYS_CONTAINER_NAME \
        $python_bin_path \
        $path_script \
        --publish_geojson \
        --geojson_path $geojson_path \
        --shp_path "$shapefile_path" \
        --geoserver_host $GEOSERVER_CONTAINER_NAME \
        --geoserver_port $geoserver_port \
        --geoserver_username admin \
        --geoserver_password geoserver
}


_check_for_existing_tethys_image() {
    printf "${YELLOW}Select an option (type a number): ${RESET}\n"
    options=("Run Tethys using existing local docker image" "Run Tethys after updating to latest docker image" "Exit")
    select option in "${options[@]}"; do
        case $option in
            "Run Tethys using existing local docker image")
                printf "${GREEN}Using local image of the Tethys platform${RESET}\n"
                return 0
                ;;
            "Run Tethys after updating to latest docker image")
                printf "${GREEN}Pulling container...${RESET}\n"
                if ! docker pull "$TETHYS_IMAGE_NAME"; then
                    printf "${RED}Failed to pull Docker image: $TETHYS_IMAGE_NAME${RESET}\n" >&2
                    return 1
                fi
                return 0
                ;;
            "Exit")
                printf "${CYAN}Have a nice day!${RESET}\n"
                _tear_down
                exit 0
                ;;
            *)
                printf "${RED}Invalid option $REPLY, 1 to continue with existing local image, 2 to update and run, and 3 to exit${RESET}\n"
                ;;
        esac
    done
}


_tear_down_tethys(){
    if [ "$(docker ps -aq -f name=$TETHYS_CONTAINER_NAME)" ]; then
        docker stop $TETHYS_CONTAINER_NAME > /dev/null 2>&1
    fi
}


_prepare_hydrofabrics(){
    local python_bin_path="/opt/conda/envs/tethys/bin/python"
    local path_script="/usr/lib/tethys/apps/ngiab/cli/convert_geom.py"
    local catchment_gpkg_layer="divides"
    local nexus_gpkg_layer="nexus"
    local gpkg_file_path="$APP_WORKSPACE_PATH/ngen-data/config/datastream.gpkg"
    local catchment_geojson_path="$APP_WORKSPACE_PATH/ngen-data/config/catchments.geojson"
    local nexus_geojson_path="$APP_WORKSPACE_PATH/ngen-data/config/nexus.geojson"
    

    # Auto-selecting files if only one is found
    echo -e "${CYAN}Preparing the catchtments...${RESET}"
    # selected_catchment=$(_auto_select_file "$HYDRO_FABRIC")
    selected_catchment=$(_auto_select_file "$CATCHMENT_FILE")
    if [[ $selected_catchment ]]; then
        _publish_geojson_layer_to_geoserver
    else
        selected_catchment=$(_auto_select_file "$HYDRO_FABRIC")
        echo $selected_catchment
        if [[ "$selected_catchment" == "$DATA_FOLDER_PATH/config/datastream.gpkg" ]]; then
            _convert_gpkg_to_geojson \
                $python_bin_path \
                $path_script \
                $gpkg_file_path \
                $catchment_gpkg_layer \
                $catchment_geojson_path
            _publish_gpkg_layer_to_geoserver
        else
            n1=${selected_catchment:-$(read -p "Enter the hydrofabric catchment geojson file path: " n1; echo "$n1")}
            local catchmentfilename=$(basename "$n1")
            local catchment_path_check="$DATA_FOLDER_PATH/config/$catchmentfilename"
            if [[ -e "$catchment_path_check" ]]; then
                if [[ "$catchmentfilename" != "nexus.json" ]]; then
                    _execute_command docker cp $n1 $TETHYS_CONTAINER_NAME:$TETHYS_PERSIST_PATH/ngen-data/config/catchments.geojson
                fi
            else
                    _execute_command docker cp $n1 $TETHYS_CONTAINER_NAME:$TETHYS_PERSIST_PATH/ngen-data/config/catchments.geojson
            fi
            _publish_geojson_layer_to_geoserver

        fi
    fi

    echo -e "${CYAN}Preparing the nexus...${RESET}"
    # selected_nexus=$(_auto_select_file "$HYDRO_FABRIC")

    selected_nexus=$(_auto_select_file "$NEXUS_FILE")
    if [[ $selected_nexus ]]; then
        _execute_command docker cp $selected_nexus $TETHYS_CONTAINER_NAME:$TETHYS_PERSIST_PATH/ngen-data/config/nexus.geojson
    else
        selected_nexus=$(_auto_select_file "$HYDRO_FABRIC")
        if [[ "$selected_nexus" == "$DATA_FOLDER_PATH/config/datastream.gpkg" ]]; then
            _convert_gpkg_to_geojson \
                $python_bin_path \
                $path_script \
                $gpkg_file_path \
                $nexus_gpkg_layer \
                $nexus_geojson_path
        else
            n2=${selected_nexus:-$(read -p "Enter the hydrofabric nexus geojson file path: " n2; echo "$n2")} 
            local nexusfilename=$(basename "$n2")
            local nexus_path_check="$DATA_FOLDER_PATH/config/$nexusfilename"

            if [[ -e "$nexus_path_check" ]]; then
                if [[ "$nexusfilename" != "nexus.json" ]]; then
                    _execute_command docker cp $n2 $TETHYS_CONTAINER_NAME:$TETHYS_PERSIST_PATH/ngen-data/config/nexus.geojson
                fi
            else
                _execute_command docker cp $n2 $TETHYS_CONTAINER_NAME:$TETHYS_PERSIST_PATH/ngen-data/config/nexus.geojson
            fi

        fi
    fi
    
}
_run_tethys(){
    docker run --rm -it -d \
    -v "$DATA_FOLDER_PATH:$TETHYS_PERSIST_PATH/ngen-data" \
    -p 80:80 \
    --platform $PLATFORM \
    --network $DOCKER_NETWORK \
    --name "$TETHYS_CONTAINER_NAME" \
    --env MEDIA_ROOT="$TETHYS_PERSIST_PATH/media" \
    --env MEDIA_URL="/media/" \
    $TETHYS_IMAGE_NAME 
    #> /dev/null 2>&1
}


# Create tethys portal
create_tethys_portal(){
    read -r visualization_choice
    echo -e "${YELLOW}Do you want to visualize your outputs using tethys? (y/N, default: y):${RESET}"
    # Execute the command
    if [[ "$visualization_choice" == [Yy]* ]]; then
        echo -e "${GREEN}Setup Tethys Portal image...${RESET}"
        _create_tethys_docker_network
        if _check_for_existing_tethys_image; then
            _run_containers
            
            echo -e "${CYAN}Link data to the Tethys app workspace.${RESET}"
            _link_data_to_app_workspace         
            echo -e "${GREEN}Preparing the hydrofabrics for the portal...${RESET}"
            _prepare_hydrofabrics
            
            echo -e "${GREEN}Your outputs are ready to be visualized at http://localhost/apps/ngiab ${RESET}"
            echo -e "${MAGENTA}You can use the following to login: ${RESET}"
            echo -e "${CYAN}user: admin${RESET}"
            echo -e "${CYAN}password: pass${RESET}"

            _pause_script_execution
        else
            printf "${RED}Failed to prepare Tethys portal.${RESET}\n"
        fi
    else
        printf "${CYAN}Skipping Tethys visualization setup.${RESET}\n"
    fi
}


##########################
#####START OF SCRIPT######
##########################

# Set up the SIGINT trap to call the handle_sigint function
trap handle_sigint SIGINT

# Constanst
PLATFORM='linux/amd64'
TETHYS_CONTAINER_NAME="tethys-ngen-portal"
GEOSERVER_CONTAINER_NAME="tethys-geoserver"
GEOSERVER_PORT_CONTAINER="8080"
GEOSERVER_PORT_HOST="8181"
DOCKER_NETWORK="tethys-network"
APP_WORKSPACE_PATH="/usr/lib/tethys/apps/ngiab/tethysapp/ngiab/workspaces/app_workspace"
TETHYS_IMAGE_NAME=gioelkin/tethys-ngiab:dev
GEOSERVER_IMAGE_NAME=docker.osgeo.org/geoserver:2.25.x
DATA_FOLDER_PATH="$1"
TETHYS_PERSIST_PATH="/var/lib/tethys_persist"
CONFIG_FILE="$HOME/.host_data_path.conf"

# check for architecture
if uname -a | grep arm64 || uname -a | grep aarch64 ; then
    PLATFORM=linux/arm64
else
    PLATFORM=linux/amd64
fi


check_last_path "$@"

create_tethys_portal

