#!/usr/bin/env python3

import re
import subprocess
import json
import sys
import os
from datetime import datetime
from collections import Counter, defaultdict
import ipaddress

# Constants
SUSPICIOUS_PATTERNS = [
    r'wp-login\.php',
    r'wp-admin',
    r'\.git',
    r'\.env',
    r'/admin',
    r'/phpMyAdmin',
    r'/phpmyadmin',
    r'/solr',
    r'/jenkins',
    r'select.*from',
    r'union.*select',
    r'eval\(',
    r'exec\(',
    r'["\'].*<script',
]


class WebTrafficAnalyzer:
    def __init__(self):
        self.ips = Counter()
        self.countries = Counter()
        self.error_types = Counter()
        self.suspicious_ips = defaultdict(list)
        self.total_connections = 0
        self.unknown_hosts = 0
        self.connection_errors = 0
        self.requests = []
        self.ip_details = {}  # Store details about each IP

    def get_traefik_logs(self):
        """Extract logs from Docker container running Traefik"""
        try:
            cmd = ["docker", "logs", "traefik"]
            result = subprocess.run(cmd, capture_output=True, text=True)
            return result.stdout.splitlines()
        except subprocess.SubprocessError as e:
            print(f"Error retrieving Traefik logs: {e}")
            return []

    def get_country_from_ip(self, ip):
        """Get country from IP address using geoiplookup"""
        try:
            cmd = ["geoiplookup", ip]
            result = subprocess.run(cmd, capture_output=True, text=True)
            country_match = re.search(r'GeoIP Country Edition: ([^,]+)', result.stdout)
            if country_match:
                return country_match.group(1).strip()
            return "Unknown"
        except (subprocess.SubprocessError, FileNotFoundError):
            return "Unknown"

    def is_private_ip(self, ip):
        """Check if IP is private/internal"""
        try:
            return ipaddress.ip_address(ip).is_private
        except ValueError:
            return False

    def extract_ip_and_port_from_log(self, line):
        """Extract IP addresses and ports from a log line using various patterns"""
        # First try to find IP:PORT format (most common in connection logs)
        ip_port_match = re.search(r'tcp ([\d.:]+)->([^:]+):(\d+)', line)
        if ip_port_match:
            local_endpoint = ip_port_match.group(1)
            remote_ip = ip_port_match.group(2)
            remote_port = ip_port_match.group(3)
            
            # Extract local port from local_endpoint (format: 172.27.0.4:443)
            local_port_match = re.search(r':(\d+)$', local_endpoint)
            local_port = local_port_match.group(1) if local_port_match else "Unknown"
            
            return {
                "ip": remote_ip,
                "remote_port": remote_port,
                "local_port": local_port
            }
            
        # Next try to find standalone IP addresses
        ip_patterns = [
            (r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):', None),
            (r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) -', None),
            (r'client=(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', None),
            (r'rejecting "([^"]+)"', None) # For rejected connections
        ]
        
        for pattern, port_pattern in ip_patterns:
            ip_match = re.search(pattern, line)
            if ip_match:
                remote_ip = ip_match.group(1)
                
                # Try to extract port information if available
                port_info = "Unknown"
                if port_pattern:
                    port_match = re.search(port_pattern, line)
                    if port_match:
                        port_info = port_match.group(1)
                
                return {
                    "ip": remote_ip,
                    "remote_port": "Unknown",
                    "local_port": "Unknown"
                }
                
        return None

    def parse_traefik_log_line(self, line):
        """Parse a Traefik log line for connection information"""
        timestamp_match = re.search(r'time="([^"]+)"', line)
        timestamp = timestamp_match.group(1) if timestamp_match else "Unknown"
        
        # Extract IP address and port info
        ip_data = self.extract_ip_and_port_from_log(line)
        if not ip_data:
            return None
            
        ip = ip_data["ip"]
            
        # Skip private/internal IPs
        if self.is_private_ip(ip):
            return None
            
        # Extract error type
        error_type = "Unknown"
        
        # Connection timeout/error
        if "read: connection timed out" in line:
            error_type = "Connection Timeout"
        elif "read: connection reset by peer" in line:
            error_type = "Connection Reset"
        elif "write: broken pipe" in line:
            error_type = "Broken Pipe"
        # Rejected connections
        elif "Could not retrieve CanonizedHost, rejecting" in line:
            error_type = "Host Rejected"
        # TLS errors
        elif "TLS handshake error" in line:
            error_type = "TLS Handshake Error"
        # Look for other errors
        elif "level=error" in line:
            error_match = re.search(r'msg="([^"]+)"', line)
            if error_match:
                error_type = error_match.group(1)
                
        # Try to extract path if available
        path = "Unknown"
        path_match = re.search(r'"(GET|POST|PUT|DELETE) ([^"]+)"', line)
        if path_match:
            path = path_match.group(2)
            
        # Try to extract the domain/host if available
        host = "Unknown"
        host_match = re.search(r'Host\(`([^`]+)`\)', line)
        if not host_match:
            host_match = re.search(r'Host: ([^\s,]+)', line)
        if host_match:
            host = host_match.group(1)
            
        is_suspicious = self.is_suspicious(line)
        
        return {
            "ip": ip,
            "timestamp": timestamp,
            "error_type": error_type,
            "path": path,
            "host": host,
            "remote_port": ip_data["remote_port"],
            "local_port": ip_data["local_port"],
            "suspicious": is_suspicious,
            "raw_log": line[:150]  # Store part of raw log for reference
        }

    def is_suspicious(self, log_line):
        """Check if the log line contains suspicious patterns"""
        for pattern in SUSPICIOUS_PATTERNS:
            if re.search(pattern, log_line, re.IGNORECASE):
                return True
        return False

    def analyze_logs(self):
        """Analyze Docker logs from Traefik"""
        print("Collecting Traefik logs from Docker container...")
        docker_logs = self.get_traefik_logs()
        
        if not docker_logs:
            print("No Traefik logs found in Docker container.")
            return
            
        print(f"Processing {len(docker_logs)} log lines...")
        processed = 0
        
        for line in docker_logs:
            # Skip internal or service startup messages
            if "level=info msg=\"Starting provider" in line or "Configuration loaded" in line:
                continue
                
            data = self.parse_traefik_log_line(line)
            if data:
                self.process_log_entry(data)
                processed += 1
                
        print(f"Successfully processed {processed} connection attempts.")
        self.total_connections = processed

    def process_log_entry(self, data):
        """Process a parsed log entry"""
        self.ips[data["ip"]] += 1
        
        # Store details about this IP if we haven't already
        if data["ip"] not in self.ip_details:
            country = self.get_country_from_ip(data["ip"])
            self.ip_details[data["ip"]] = {
                "country": country,
                "ports_accessed": set(),
                "endpoints": set()
            }
            self.countries[country] += 1
        
        # Update the port and endpoint information
        self.ip_details[data["ip"]]["ports_accessed"].add(data["local_port"])
        
        endpoint = f"{data['host']}{data['path']}" if data["path"] != "Unknown" else "Unknown"
        self.ip_details[data["ip"]]["endpoints"].add(endpoint)
        
        # Count error types
        if data["error_type"] != "Unknown":
            self.error_types[data["error_type"]] += 1
            
        if data["error_type"] == "Host Rejected":
            self.unknown_hosts += 1
        elif "Connection" in data["error_type"] or "Error" in data["error_type"]:
            self.connection_errors += 1
            
        # Save suspicious activities
        if data["suspicious"]:
            self.suspicious_ips[data["ip"]].append({
                "timestamp": data["timestamp"],
                "error_type": data["error_type"],
                "endpoint": endpoint,
                "local_port": data["local_port"],
                "raw_log": data["raw_log"]
            })
            
        # Save request data for detailed analysis
        self.requests.append(data)

    def print_report(self):
        """Print a human-readable report"""
        print("\n" + "="*80)
        print(f"WEB TRAFFIC ANALYSIS REPORT - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print("="*80 + "\n")
        
        if self.total_connections == 0:
            print("No connection attempts found to analyze.")
            print("\nPossible reasons:")
            print("1. Your Traefik container might be new with few connections")
            print("2. Log format might not match what the script expects")
            return
            
        print(f"Total connection attempts analyzed: {self.total_connections}")
        print(f"Rejected unknown hosts: {self.unknown_hosts}")
        print(f"Connection errors/timeouts: {self.connection_errors}")
        print()
        
        # Print suspicious activity
        if self.suspicious_ips:
            print("\nSUSPICIOUS ACTIVITY DETECTED:")
            print("-"*80)
            for ip, events in self.suspicious_ips.items():
                country = self.ip_details[ip]["country"]
                print(f"\nIP: {ip} ({country})")
                print(f"Total suspicious events: {len(events)}")
                print("Sample events:")
                for i, event in enumerate(events[:5]):  # Show at most 5 examples
                    print(f"  {i+1}. [{event['timestamp']}] {event['error_type']} - Port: {event['local_port']}")
                    print(f"     Endpoint: {event['endpoint']}")
                    print(f"     {event['raw_log']}")
                if len(events) > 5:
                    print(f"  ... and {len(events) - 5} more")
            print("-"*80)
        
        # Print top IPs
        print("\nTOP 10 CONNECTING IP ADDRESSES:")
        print("-"*80)
        for ip, count in self.ips.most_common(10):
            country = self.ip_details[ip]["country"]
            ports = ", ".join(sorted(self.ip_details[ip]["ports_accessed"]))
            print(f"{ip} ({country}):")
            print(f"  Connection attempts: {count}")
            print(f"  Ports accessed: {ports}")
            
            # Show endpoints if known
            endpoints = self.ip_details[ip]["endpoints"]
            if endpoints and endpoints != {"Unknown"}:
                print(f"  Endpoints: {', '.join(sorted(endpoints))}")
            print()
        
        # Print top countries
        print("\nTOP 5 COUNTRIES:")
        print("-"*80)
        for country, count in self.countries.most_common(5):
            print(f"{country}: {count} connection attempts")
        
        # Print error distribution
        print("\nERROR TYPES DISTRIBUTION:")
        print("-"*80)
        for error, count in self.error_types.most_common():
            print(f"{error}: {count} occurrences")
        
        print("\n" + "="*80)
        print("END OF REPORT")
        print("="*80 + "\n")


if __name__ == "__main__":
    # Check if Docker is running
    try:
        subprocess.run(["docker", "ps"], check=True, capture_output=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: Docker is not running or not installed.")
        sys.exit(1)
    
    # Check if geoiplookup is installed
    try:
        subprocess.run(["which", "geoiplookup"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        print("Warning: geoiplookup is not installed. Country information will not be available.")
        print("Install it with: sudo apt-get install geoip-bin")
    
    try:
        import ipaddress
    except ImportError:
        print("Warning: ipaddress module not found. This should be included in Python 3.x.")
        print("If you're using an older Python version, install it with: pip3 install ipaddress")
        sys.exit(1)
    
    analyzer = WebTrafficAnalyzer()
    analyzer.analyze_logs()
    analyzer.print_report()