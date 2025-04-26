#!/usr/bin/env python3
import os
import requests
import logging
import time

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('dns-setup')

# Get environment variables
CLOUDFLARE_API_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN")
CLOUDFLARE_EMAIL = os.environ.get("CLOUDFLARE_EMAIL")
CLOUDFLARE_ZONE_ID = os.environ.get("CLOUDFLARE_ZONE_ID")
DOMAIN = os.environ.get("DOMAIN")

# List of all subdomain variables to check
SUBDOMAIN_VARS = [
    "DASHBOARD_SUBDOMAIN",
    "AUTHELIA_SUBDOMAIN",
    "GLANCES_SUBDOMAIN",
    "JELLYFIN_SUBDOMAIN",
    "WIREGUARD_SUBDOMAIN"
]

# API endpoint for DNS records
API_ENDPOINT = f"https://api.cloudflare.com/client/v4/zones/{CLOUDFLARE_ZONE_ID}/dns_records"

# Headers for API requests
headers = {
    "Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}",
    "Content-Type": "application/json"
}

def check_dns_record_exists(name):
    """Check if a DNS record already exists and its properties"""
    full_name = f"{name}.{DOMAIN}"
    logger.info(f"Checking if DNS record exists: {full_name}")
    
    response = requests.get(API_ENDPOINT, headers=headers, params={"name": full_name})
    if response.status_code == 200:
        data = response.json()
        records = data["result"]
        if len(records) > 0:
            # Record exists, check if it's proxied
            record = records[0]
            logger.info(f"DNS record '{full_name}' already exists")
            
            # If proxied, it may need to be updated
            if record.get("proxied", False) is True:
                logger.info(f"DNS record '{full_name}' is currently proxied, needs update")
                return {"exists": True, "record_id": record["id"], "needs_update": True}
            
            return {"exists": True, "record_id": record["id"], "needs_update": False}
    
    logger.info(f"DNS record '{full_name}' does not exist")
    return {"exists": False}

def update_dns_record(record_id, name):
    """Update an existing DNS record to be non-proxied"""
    full_name = f"{name}.{DOMAIN}"
    
    record_data = {
        "type": "CNAME",
        "name": name,
        "content": DOMAIN,
        "ttl": 3600,  # 1 hour TTL
        "proxied": False  # DNS only, no Cloudflare proxy
    }
    
    logger.info(f"Updating DNS record to be non-proxied: {full_name}")
    update_url = f"{API_ENDPOINT}/{record_id}"
    response = requests.put(update_url, headers=headers, json=record_data)
    
    if response.status_code == 200:
        logger.info(f"Successfully updated DNS record for '{full_name}' to be non-proxied")
    else:
        logger.error(f"Failed to update DNS record for '{full_name}'")
        logger.error(f"Status code: {response.status_code}")
        logger.error(f"Response: {response.text}")

def create_dns_cname_record(name):
    """Create or update a DNS CNAME record"""
    full_name = f"{name}.{DOMAIN}"
    
    # Check if record exists and if it needs updates
    record_check = check_dns_record_exists(name)
    
    if record_check["exists"]:
        if record_check["needs_update"]:
            # Record exists but is proxied, needs to be updated
            update_dns_record(record_check["record_id"], name)
        else:
            # Record exists and is already non-proxied
            logger.info(f"Skipping creation for '{full_name}' as it already exists and is not proxied")
        return
    
    # Record doesn't exist, create it
    record_data = {
        "type": "CNAME",
        "name": name,
        "content": DOMAIN,
        "ttl": 3600,  # 1 hour TTL
        "proxied": False  # DNS only, no Cloudflare proxy
    }
    
    logger.info(f"Creating DNS CNAME record: {full_name} -> {DOMAIN}")
    response = requests.post(API_ENDPOINT, headers=headers, json=record_data)
    
    if response.status_code == 200:
        logger.info(f"Successfully created DNS record for '{full_name}'")
    else:
        logger.error(f"Failed to create DNS record for '{full_name}'")
        logger.error(f"Status code: {response.status_code}")
        logger.error(f"Response: {response.text}")

def verify_dns_propagation(name, max_retries=20, retry_delay=10):
    """Verify DNS propagation by checking the record multiple times"""
    full_name = f"{name}.{DOMAIN}"
    logger.info(f"Verifying DNS propagation for: {full_name}")
    
    for attempt in range(1, max_retries + 1):
        response = requests.get(API_ENDPOINT, headers=headers, params={"name": full_name})
        if response.status_code == 200:
            data = response.json()
            records = data["result"]
            if len(records) > 0:
                logger.info(f"DNS record '{full_name}' verified (attempt {attempt}/{max_retries})")
                return True
        
        logger.warning(f"DNS record '{full_name}' not yet propagated (attempt {attempt}/{max_retries})")
        if attempt < max_retries:
            logger.info(f"Waiting {retry_delay} seconds before next check...")
            time.sleep(retry_delay)
    
    logger.error(f"DNS propagation verification failed for '{full_name}' after {max_retries} attempts")
    return False

def main():
    """Main function to check and create DNS records"""
    logger.info("Starting DNS setup script")
    
    # Validate required environment variables
    if not all([CLOUDFLARE_API_TOKEN, CLOUDFLARE_EMAIL, CLOUDFLARE_ZONE_ID, DOMAIN]):
        logger.error("Missing required environment variables")
        return
    
    logger.info(f"Working with domain: {DOMAIN}")
    
    # Process each subdomain
    created_records = []
    for var_name in SUBDOMAIN_VARS:
        subdomain = os.environ.get(var_name)
        if subdomain:
            logger.info(f"Processing {var_name}={subdomain}")
            record_check = check_dns_record_exists(subdomain)
            if not record_check["exists"]:
                create_dns_cname_record(subdomain)
                created_records.append(subdomain)
            elif record_check.get("needs_update", False):
                update_dns_record(record_check["record_id"], subdomain)
                created_records.append(subdomain)
            else:
                logger.info(f"Skipping creation for '{subdomain}.{DOMAIN}' as it already exists and is not proxied")
        else:
            logger.warning(f"Environment variable {var_name} not found")
    
    # Verify DNS propagation for newly created or updated records
    if created_records:
        logger.info(f"Waiting for DNS propagation for {len(created_records)} records...")
        time.sleep(30)  # Longer initial wait for DNS changes to start propagating
        
        # Verify all subdomains are propagated
        for subdomain in created_records:
            verify_dns_propagation(subdomain)
        
        # Final wait to ensure DNS is fully propagated before Traefik tries ACME verification
        logger.info("DNS records created and verified. Waiting 60 more seconds for full propagation...")
        time.sleep(60)
    
    logger.info("DNS setup completed")

if __name__ == "__main__":
    # Add a small delay to ensure network is ready
    time.sleep(2)
    main()