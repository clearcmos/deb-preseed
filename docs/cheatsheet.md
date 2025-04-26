# validate subdomains cnames and create if needed
sudo -E docker-compose --env-file /etc/secrets/.docker run --rm dns-setup
