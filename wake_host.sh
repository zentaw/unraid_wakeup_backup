#!/bin/bash

initialize_variables() {
    PRIMARY_HOST="10.0.0.20" # IP of host to start.
    PRIMARY_HOST_MAC="AA:AA:AA:AA:AA:AA" # MAC adress if using wake on lan.
    PRIMARY_HOST_SSH_USERNAME="root" # Replace with your SSH username, only developed for root so far.
    PRIMARY_HOST_SSH_PASSWORD="" # Replace with your SSH password or leave empty if using SSH keys
    SECONDARY_HOST="10.0.0.1" # If PRIMARY_HOST dosent respond this host can be checked if net is down.
    WIFI_PLUG_IP="10.0.0.110" # Replace with the actual IP address of your wifi-plug
    WIFI_PLUG_USERNAME="admin" # Replace with your wifi-plug username
    WIFI_PLUG_PASSWORD="SuperSecretPassword" # Replace with your wifi-plug password
    WIFI_PLUG_POWER_DRAW_THRESHOLD="5" # Safeguard to not turn of WIFI_PLUG if powerdraw is equal or higher to this value.

    # Define the location of scripts to be imported and run
    IMPORTED_SCRIPTS=(
        "/boot/config/plugins/user.scripts/scripts/Unraid_ZFS_Dataset_Snapshot_and_Replications/script"
        # Add more script paths here
    )
}

# Function to check WiFi plug status
check_wifi_plug_status() {
    local status=$(curl "http://$WIFI_PLUG_IP/relay/0" -u "$WIFI_PLUG_USERNAME:$WIFI_PLUG_PASSWORD" 2>/dev/null)
    
    if [[ "$status" == *"\"ison\":true"* ]]; then
        wifi_plug_status="on"
    elif [[ "$status" == *"\"ison\":false"* ]]; then
        wifi_plug_status="off"
    else
        wifi_plug_status="unknown"
    fi
}

# Function to control WiFi plug
control_wifi_plug() {
    local action="$1"  # "on" or "off"
    
    if [[ "$action" == "on" ]]; then
        curl "http://$WIFI_PLUG_IP/relay/0?turn=on" -u "$WIFI_PLUG_USERNAME:$WIFI_PLUG_PASSWORD" >/dev/null 2>&1
        echo "WiFi plug turned ON."
    elif [[ "$action" == "off" ]]; then
        curl "http://$WIFI_PLUG_IP/relay/0?turn=off" -u "$WIFI_PLUG_USERNAME:$WIFI_PLUG_PASSWORD" >/dev/null 2>&1
        echo "WiFi plug turned off"
    else
        echo "Invalid action. Use 'on' or 'off'."
    fi
}

# Function get current powerdraw
get_power_draw() {
    local response=$(curl "http://$WIFI_PLUG_IP/meter/0" -u "$WIFI_PLUG_USERNAME:$WIFI_PLUG_PASSWORD" 2>/dev/null)
    local power_draw=$(echo "$response" | grep -oE '"power":[0-9]+\.[0-9]+' | cut -d':' -f2)
    
    echo "$power_draw"
}

# Function to send Wake-on-LAN magic packet
send_wol_magic_packet() {
    etherwake -b "$PRIMARY_HOST_MAC"
    primary_host_etherwake="true"
}

# Function to check if PRIMARY_HOST is running
primary_host_was_running() {
    if ping -c 1 "$PRIMARY_HOST" >/dev/null; then
        primary_host_status="true"
    else
        primary_host_status="false"
    fi
}

# Function to perform SSH shutdown
perform_ssh_shutdown() {
    local ssh_command=""
    echo "Sending Unraid powerdown to host $PRIMARY_HOST"
    if [ -n "$PRIMARY_HOST_SSH_PASSWORD" ]; then
        ssh_command="sshpass -p '$PRIMARY_HOST_SSH_PASSWORD' ssh '$PRIMARY_HOST_SSH_USERNAME'@'$PRIMARY_HOST' 'powerdown'"
    else
        ssh_command="ssh-agent bash -c 'ssh-add; ssh $PRIMARY_HOST_SSH_USERNAME@$PRIMARY_HOST \"powerdown\"'"
    fi
    eval "$ssh_command" >/dev/null 2>&1
}

# Function to wait for ping response
primary_host_wait_for_poweron() {
    local max_response_checks=100
    local required_successful_responses=5
    
    while true; do
        local response_count=0
        local successful_responses=0
        
        # Ping loop
        while ((response_count < max_response_checks)); do
            if ping -c 1 "$PRIMARY_HOST" > /dev/null; then
                ((response_count++))
                ((successful_responses++))
                echo "Ping response received $successful_responses of $required_successful_responses required"
                
                if ((successful_responses >= required_successful_responses)); then
                    echo "Primary host is turned on"
                    primary_host_is_poweredon=true
                    return
                fi
            else
                ((response_count++))
                echo "No ping response received $response_count of $max_response_checks tries"
                successful_responses=0  # Reset successful_responses on failure
            fi
            
            sleep 1
        done
        
        # No response after max_response_checks
        echo "No response after $max_response_checks tries. Host is not turned on."
        primary_host_is_poweredon=false
        return
    done
}

# Function to wait ping response to end.
primary_host_wait_for_shutdown() {
    local max_no_responses=100
    local required_successful_no_responses=5
    
    while true; do
        local no_response_count=0
        local successful_no_responses=0
        
        # Ping loop
        while ((no_response_count < max_no_responses)); do
            if ping -c 1 "$PRIMARY_HOST" > /dev/null; then
                ((no_response_count++))
                echo "Ping response received $no_response_count/$max_no_responses"
                sleep 2
                successful_no_responses=0  # Reset successful_no_responses on success
            else
                ((no_response_count++))
                ((successful_no_responses++))
                echo "No ping response received $successful_no_responses of $required_successful_no_responses required"
                
                if ((successful_no_responses >= required_successful_no_responses)); then
                    echo "Primary host is shutdown"
                    primary_host_is_shutdown=true
                    return
                fi
            fi
            
            sleep 1
        done
        
        # Ping response after max_no_responses
        echo "Ping response received. Primary host is not fully shutdown."
        primary_host_is_shutdown=false
        return
    done
}

# Function to check if Unraid Array is online.
check_array_online() {
    local MAX_RETRIES=5
    local RETRY_INTERVAL=60
    array_is_started=false

    for ((retry_count = 1; retry_count <= MAX_RETRIES; retry_count++)); do
        echo "Attempt $retry_count of $MAX_RETRIES: Checking if array is STARTED..."
        ssh "$PRIMARY_HOST_SSH_USERNAME@$PRIMARY_HOST" "mdcmd status | grep STARTED" >/dev/null 2>&1
        exit_status=$?

        if [[ $exit_status -eq 0 ]]; then
            echo "Array is started. Continuing..."
            array_is_started=true
            break
        else
            echo "Array is not started. Retrying in $RETRY_INTERVAL seconds..."
            sleep $RETRY_INTERVAL

            if [[ $retry_count -eq MAX_RETRIES ]]; then
                echo "Array did not start after $MAX_RETRIES retries. Cannot proceed."
                array_is_started=false
            fi
        fi
    done
}

# Function to run each imported script in list.
run_scripts() {
    if [[ "$array_is_started" == "true" ]]; then
        echo "Running imported scripts"
        for imported_script in "${IMPORTED_SCRIPTS[@]}"; do
            bash "$imported_script"
        done
    else
        echo "Array is not started. Imported scripts will not be run."
    fi
}


initialize_variables
primary_host_was_running
check_wifi_plug_status

# Step 1 If host is turned off check WiFi plug on/off status, either way turn on host.
if [[ "$primary_host_status" == "false" ]]; then
    if [[ "$wifi_plug_status" == "off" ]]; then
        echo "WiFi plug is off. Turning it on..."
        current_power_draw=$(get_power_draw)
        echo "Current power draw: $current_power_draw W"
        control_wifi_plug "on"
    else
        echo "WiFi plug is on."
        current_power_draw=$(get_power_draw)
        echo "Current power draw: $current_power_draw W"
        echo "Sending Wake-on-LAN magic packet to primary host..."
        send_wol_magic_packet
    fi
fi

# Step 2 Host powered on, run imported scripts if Unraid array is online
primary_host_wait_for_poweron
if [[ "$primary_host_is_poweredon" == "true" ]]; then
    check_array_online
    run_scripts
fi

# Step 3 Host already running, dont turn off
if [[ "$primary_host_status" == "true" ]]; then
    current_power_draw=$(get_power_draw)
    echo "Current power draw: $current_power_draw W"    
    echo "Host was already running when starting script. Not turning off"
fi

# Step 4 Host woken by wake on lan, turn off. Leave WiFi plug unchanged
if [[ "$primary_host_etherwake" == "true" ]]; then
    echo "Shutting down primary host..."
    perform_ssh_shutdown
    primary_host_wait_for_shutdown
    if [[ "$primary_host_is_shutdown" == "true" ]]; then
        current_power_draw=$(get_power_draw)
        echo "Current power draw: $current_power_draw W"
        primary_host_status="true"
        echo "not turning off WiFi plug"
    fi
fi

# Step 5 Host woken by WiFi plug power on, turn off. Turn off WiFi plug
if [[ "$primary_host_status" == "false" ]]; then
    echo "Shutting down primary host..."
    perform_ssh_shutdown
    primary_host_wait_for_shutdown
    if [[ "$primary_host_is_shutdown" == "true" ]]; then
        current_power_draw=$(get_power_draw)
        echo "Current power draw: $current_power_draw W"
        current_power_draw_int=${current_power_draw%.*}  # Truncate decimal part
        if (( current_power_draw_int < WIFI_PLUG_POWER_DRAW_THRESHOLD )); then
            echo "Current power draw is less then $WIFI_PLUG_POWER_DRAW_THRESHOLD W. Turning off WiFi plug"
            control_wifi_plug "off"
        fi
    fi
fi

echo "All in a days work"
