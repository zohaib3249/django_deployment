#!/bin/bash
# run bash with 'source server.sh '
# Variables
DOMAIN=""
IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d / -f 1)
PROJECT_NAME="DEMO_buses"
USER=$(whoami)
DATABASE=Database_name
PROJECT_DIR="/home/$USER/$PROJECT_NAME"
STATIC_DIR="$PROJECT_DIR/static"
MEDIA_DIR="$PROJECT_DIR/media/"
VIRTUAL_ENV_DIR="$PROJECT_DIR/envs"
VIRTUAL_ENV="$PROJECT_DIR/envs/venv"
UWSGI_SOCKET_DIR="/run/uwsgi"
UWSGI_SOCKET="$UWSGI_SOCKET_DIR/$PROJECT_NAME.sock"
UWSGI_MODULE="$PROJECT_NAME.wsgi:application"



# Update system
sudo apt update
sudo apt upgrade -y

# Install required packages
sudo apt install python3-pip -y
sudo apt install python3-venv  -y
sudo apt install nginx -y
sudo apt install uwsgi -y
sudo apt install uwsgi-plugin-python3 -y



# Remove existing uWSGI configuration files
sudo rm -f /etc/uwsgi/apps-available/$PROJECT_NAME.ini
sudo rm -f /etc/uwsgi/apps-enabled/$PROJECT_NAME.ini
sudo rm -f $UWSGI_SOCKET
# Remove existing Nginx configuration files
sudo rm -f /etc/nginx/sites-available/$PROJECT_NAME
sudo rm -f /etc/nginx/sites-enabled/$PROJECT_NAME

sudo apt install python3-virtualenv -y

# Create a virtual environment
if ! command -v virtualenv &> /dev/null; then
    pip install virtualenv
fi
sudo apt install postgresql postgresql-contrib -y
sudo systemctl start postgresql.service
# Run PostgreSQL commands as the postgres user
sudo -u postgres psql << EOF
CREATE DATABASE $DATABASE;
CREATE USER $USER WITH PASSWORD 'root';
ALTER ROLE $USER SET client_encoding TO 'utf8';
ALTER ROLE $USER SET default_transaction_isolation TO 'read committed';
ALTER ROLE $USER SET timezone TO 'UTC';
GRANT ALL PRIVILEGES ON DATABASE $DATABASE TO $USER;
EOF

echo "PostgreSQL setup complete!"

# Create a virtual environment using virtualenv
virtualenv $VIRTUAL_ENV_DIR/venv

# Activate the virtual environment
source $VIRTUAL_ENV_DIR/venv/bin/activate
echo "Activated environment: $VIRTUAL_ENV"

# Install project dependencies
pip install -r $PROJECT_DIR/requirements.txt
python --version
## Create uWSGI socket directory
sudo mkdir -p $UWSGI_SOCKET_DIR
sudo chown www-data:www-data $UWSGI_SOCKET_DIR
sudo gpasswd -a www-data $USER
sudo chown -R www-data:www-data $PROJECT_DIR

#
# Configure uWSGI
cat <<EOF | sudo tee /etc/uwsgi/apps-available/$PROJECT_NAME.ini
[uwsgi]
chdir = $PROJECT_DIR
uid = $USER
module = $UWSGI_MODULE
env = DJANGO_SETTINGS_MODULE=$PROJECT_NAME.settings
home = $VIRTUAL_ENV_DIR/venv
socket = $UWSGI_SOCKET
chown-socket = %(uid):www-data
chmod-socket = 660
python-path = $VIRTUAL_ENV_DIR/venv/lib/python3.10/site-packages

master = true
processes = 1

vacuum = true
plugins = python3

logto = /var/log/uwsgi/$PROJECT_NAME.log
EOF

sudo ln -s /etc/uwsgi/apps-available/$PROJECT_NAME.ini /etc/uwsgi/apps-enabled/

# Configure Nginx
if [ -n "$DOMAIN" ]; then
    SERVER_NAME="server_name $DOMAIN;";
else
    SERVER_NAME="server_name $IP;";
fi

sudo tee /etc/nginx/sites-available/$PROJECT_NAME <<EOF
server {
    listen 80;
    $SERVER_NAME

    location = /favicon.ico { access_log off; log_not_found off; }

    location /static/ {
        root $PROJECT_DIR;
    }
     location /media/ {
        alias $MEDIA_DIR; # Add this line if you have a media directory
    }
    location / {
        include uwsgi_params;
        uwsgi_pass unix:$UWSGI_SOCKET;
    }
}


EOF

sudo ln -s /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled/

# Test Nginx configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx

# Collect static files
cd $PROJECT_DIR
python manage.py collectstatic --noinput
python manage.py migrate

# Start uWSGI service
sudo systemctl start uwsgi@$PROJECT_NAME

# Enable uWSGI and Nginx to start on boot
sudo systemctl enable uwsgi@$PROJECT_NAME
sudo systemctl enable nginx
sudo systemctl daemon-reload
sudo systemctl restart uwsgi
sudo systemctl restart nginx




# Deploy Celery and Celery Beat with Supervisor
sudo apt install supervisor -y

# Configure Celery and Celery Beat Supervisor processes
cat <<EOF | sudo tee /etc/supervisor/conf.d/celery-worker.conf
[program:celery-worker]
command=$VIRTUAL_ENV_DIR/venv/bin/celery -A $PROJECT_NAME worker -l info -P solo
directory=$PROJECT_DIR
user=$USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/celery-worker.log
stderr_logfile=/var/log/supervisor/celery-worker-error.log
EOF

cat <<EOF | sudo tee /etc/supervisor/conf.d/celery-beat.conf
[program:celery-beat]
command=$VIRTUAL_ENV_DIR/venv/bin/celery -A $PROJECT_NAME beat -l info --scheduler django_celery_beat.schedulers:DatabaseScheduler
directory=$PROJECT_DIR
user=$USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/celery-beat.log
stderr_logfile=/var/log/supervisor/celery-beat-error.log
EOF

# Reread and update Supervisor
sudo supervisorctl reread
sudo supervisorctl update

# Start Celery worker and Celery Beat with Supervisor
sudo supervisorctl start celery-worker
sudo supervisorctl start celery-beat
sudo supervisorctl status celery-worker
sudo supervisorctl status celery-beat
sudo systemctl status uwsgi
sudo systemctl status nginx

echo "Deployment completed!"

