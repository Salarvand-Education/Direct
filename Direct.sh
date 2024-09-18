#!/bin/bash

# Function to execute the script and send option 24
run_remote_script_with_option() {
    local url="https://raw.githubusercontent.com/dev-ir/assistant-vps/master/install.sh"
    
    printf "Running the remote script...\n"
    
    # Fetch and run the script, sending option 24 as input
    bash <(curl -Ls "$url") <<< "24"
    
    if [[ $? -ne 0 ]]; then
        printf "Error: The remote script encountered an error.\n" >&2
        return 1
    fi

    printf "Remote script finished successfully.\n"
    return 0
}

# Main function
main() {
    run_remote_script_with_option
    if [[ $? -ne 0 ]]; then
        printf "Exiting due to script failure.\n" >&2
        return 1
    fi
}

# Execute main function
main
