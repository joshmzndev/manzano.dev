#!/usr/bin/env python3
"""
FreeRADIUS MAC Address Manager
Adds MAC addresses to FreeRADIUS users file and reboots the server.
"""

import re
import sys
import os
import subprocess
import argparse
from pathlib import Path

def normalize_mac_address(mac):
    """
    Normalize MAC address from various formats to lowercase without separators.
    Supports formats like: AA:BB:CC:DD:EE:FF, aa-bb-cc-dd-ee-ff, aa_bb_cc_dd_ee_ff, aabbccddeeff
    """
    # Remove all non-hex characters and convert to lowercase
    cleaned = re.sub(r'[^a-fA-F0-9]', '', mac.lower())
    
    # Validate MAC address format (should be exactly 12 hex characters)
    if not re.match(r'^[a-f0-9]{12}$', cleaned):
        raise ValueError(f"Invalid MAC address format: {mac}")
    
    return cleaned

def validate_mac_format(mac):
    """
    Check if the input looks like a valid MAC address in any common format.
    """
    # Common MAC address patterns
    patterns = [
        r'^([a-fA-F0-9]{2}[:-]){5}[a-fA-F0-9]{2}$',  # AA:BB:CC:DD:EE:FF or AA-BB-CC-DD-EE-FF
        r'^([a-fA-F0-9]{2}_){5}[a-fA-F0-9]{2}$',     # AA_BB_CC_DD_EE_FF
        r'^[a-fA-F0-9]{12}$',                         # AABBCCDDEEFF
        r'^([a-fA-F0-9]{4}\.){2}[a-fA-F0-9]{4}$',    # AAAA.BBBB.CCCC (Cisco format)
    ]
    
    return any(re.match(pattern, mac) for pattern in patterns)

def is_mac_already_exists(users_file, normalized_mac):
    """
    Check if the MAC address already exists in the users file.
    """
    try:
        with open(users_file, 'r') as f:
            content = f.read()
            return normalized_mac in content
    except FileNotFoundError:
        return False

def backup_users_file(users_file):
    """
    Create a backup of the users file.
    """
    backup_file = f"{users_file}.backup"
    try:
        subprocess.run(['cp', users_file, backup_file], check=True)
        print(f"Backup created: {backup_file}")
    except subprocess.CalledProcessError as e:
        print(f"Warning: Could not create backup: {e}")

def add_mac_to_users_file(users_file, normalized_mac):
    """
    Add the MAC address entry to the top of the FreeRADIUS users file.
    """
    new_entry = f'{normalized_mac} Cleartext-Password := "{normalized_mac}"\n'
    
    # Read existing content
    try:
        with open(users_file, 'r') as f:
            existing_content = f.read()
    except FileNotFoundError:
        existing_content = ""
    
    # Write new entry at the top
    with open(users_file, 'w') as f:
        f.write(new_entry)
        if existing_content and not existing_content.startswith('\n'):
            f.write('\n')
        f.write(existing_content)
    
    print(f"Added MAC address entry: {new_entry.strip()}")

def restart_freeradius():
    """
    Restart the FreeRADIUS service.
    """
    try:
        print("Restarting FreeRADIUS service...")
        subprocess.run(['systemctl', 'restart', 'freeradius'], check=True)
        print("FreeRADIUS service restarted successfully.")
    except subprocess.CalledProcessError as e:
        print(f"Error restarting FreeRADIUS service: {e}")
        return False
    return True

def reboot_server():
    """
    Reboot the server.
    """
    try:
        print("Rebooting server in 5 seconds...")
        subprocess.run(['shutdown', '-r', '+0', 'Rebooting after FreeRADIUS MAC addition'], check=True)
        print("Reboot initiated.")
    except subprocess.CalledProcessError as e:
        print(f"Error initiating reboot: {e}")
        return False
    return True

def main():
    parser = argparse.ArgumentParser(
        description='Add MAC address to FreeRADIUS users file and reboot server',
        epilog='Example: python3 freeradius_mac_adder.py AA:BB:CC:DD:EE:FF'
    )
    parser.add_argument('mac_address', help='MAC address in any common format')
    parser.add_argument('--users-file', '-f', 
                       default='/etc/freeradius/3.0/users',
                       help='Path to FreeRADIUS users file (default: /etc/freeradius/3.0/users)')
    parser.add_argument('--no-reboot', '-n', action='store_true',
                       help='Skip server reboot, only restart FreeRADIUS service')
    parser.add_argument('--dry-run', '-d', action='store_true',
                       help='Show what would be done without making changes')
    
    args = parser.parse_args()
    
    # Check if running as root
    if os.geteuid() != 0 and not args.dry_run:
        print("Error: This script must be run as root to modify system files and reboot.")
        sys.exit(1)
    
    # Validate MAC address format
    if not validate_mac_format(args.mac_address):
        print(f"Error: '{args.mac_address}' does not appear to be a valid MAC address.")
        print("Supported formats: AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, AA_BB_CC_DD_EE_FF, AABBCCDDEEFF")
        sys.exit(1)
    
    try:
        # Normalize the MAC address
        normalized_mac = normalize_mac_address(args.mac_address)
        print(f"Normalized MAC address: {normalized_mac}")
        
        if args.dry_run:
            print("\n--- DRY RUN MODE ---")
            print(f"Would add entry: {normalized_mac} Cleartext-Password := \"{normalized_mac}\"")
            print(f"Would modify file: {args.users_file}")
            if args.no_reboot:
                print("Would restart FreeRADIUS service")
            else:
                print("Would reboot server")
            return
        
        # Check if MAC already exists
        if is_mac_already_exists(args.users_file, normalized_mac):
            print(f"MAC address {normalized_mac} already exists in {args.users_file}")
            response = input("Continue anyway? (y/N): ")
            if response.lower() != 'y':
                print("Aborted.")
                sys.exit(0)
        
        # Create backup
        if Path(args.users_file).exists():
            backup_users_file(args.users_file)
        
        # Add MAC to users file
        add_mac_to_users_file(args.users_file, normalized_mac)
        
        # Restart FreeRADIUS or reboot
        if args.no_reboot:
            restart_freeradius()
        else:
            # Give user a chance to cancel
            print("\nServer will reboot in 10 seconds. Press Ctrl+C to cancel...")
            try:
                import time
                for i in range(10, 0, -1):
                    print(f"Rebooting in {i} seconds...", end='\r')
                    time.sleep(1)
                print()
                reboot_server()
            except KeyboardInterrupt:
                print("\nReboot cancelled. Restarting FreeRADIUS service instead...")
                restart_freeradius()
        
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nOperation cancelled by user.")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
