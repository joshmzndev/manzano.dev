#!/usr/bin/env python3
import re
import sys
import time
import subprocess

def normalize_mac(mac_address):
    """
    Normalize MAC address to lowercase without separators.
    Example: 4E-1D-2C-7D-B5-9A -> 4e1d2c7db59a
    
    Args:
        mac_address: MAC address in any format
    
    Returns:
        Normalized MAC address string
    """
    return re.sub(r'[:-]', '', mac_address).lower()

def is_mac_authorized(normalized_mac, auth_file='/etc/freeradius/3.0/users'):
    """
    Check if a normalized MAC address exists in the authorization file.
    
    Args:
        normalized_mac: MAC address in normalized format (e.g., e8d52b79dcc0)
        auth_file: Path to the FreeRADIUS users file
    
    Returns:
        True if MAC is found, False otherwise
    """
    try:
        with open(auth_file, 'r') as f:
            content = f.read()
            return normalized_mac in content
    except FileNotFoundError:
        print(f"Warning: Authorization file '{auth_file}' not found.")
        return False
    except PermissionError:
        print(f"Warning: Permission denied reading '{auth_file}'. May need sudo.")
        return False

def monitor_log_for_mac(log_file_path):
    """
    Monitor a log file for MAC addresses and execute a command when found.
    
    Args:
        log_file_path: Path to the log file to monitor
    """
    # MAC address pattern (matches formats like AA:BB:CC:DD:EE:FF or AA-BB-CC-DD-EE-FF)
    mac_pattern = re.compile(r'([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})')
    
    try:
        with open(log_file_path, 'r') as log_file:
            # Move to the end of the file to start monitoring new entries
            log_file.seek(0, 2)
            
            print(f"Monitoring {log_file_path} for MAC addresses...")
            
            while True:
                line = log_file.readline()
                
                if not line:
                    # No new line, wait briefly before checking again
                    time.sleep(0.1)
                    continue
                
                # Search for MAC address in the line
                match = mac_pattern.search(line)
                
                if match:
                    mac_address = match.group(0)
                    normalized_mac = normalize_mac(mac_address)
                    
                    print(f"MAC Address found: {mac_address}")
                    print(f"Normalized: {normalized_mac}")
                    
                    # Check if MAC is already authorized
                    if is_mac_authorized(normalized_mac):
                        print(f"{normalized_mac} is authorized")
                        # Don't run command, continue monitoring
                        continue
                    else:
                        print(f"{normalized_mac} is NOT authorized - executing command...")
                        
                        # Execute bash command (placeholder)
                        # Replace with your actual command
                        command = f"echo 'Adding MAC to authorized list: {normalized_mac}'"
                        
                        try:
                            result = subprocess.run(command, shell=True, capture_output=True, text=True)
                            print(f"Command output: {result.stdout.strip()}")
                            print("Exiting script.")
                            sys.exit(0)
                        except Exception as e:
                            print(f"Error executing command: {e}")
                            sys.exit(1)
    
    except FileNotFoundError:
        print(f"Error: Log file '{log_file_path}' not found.")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nMonitoring stopped.")
        sys.exit(0)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python script.py <log_file_path>")
        sys.exit(1)
    
    log_file = sys.argv[1]
    monitor_log_for_mac(log_file)
