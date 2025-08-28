#!/bin/bash
set -Eeuo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND" >&2' ERR

# Clean up stale rsyslog PID file (if it exists) and exec rsyslog
if [ -f /run/rsyslogd.pid ]; then
  rm -f /run/rsyslogd.pid
fi
exec rsyslogd -n &

. /usr/local/sbin/isrd-recipe-lib.sh

# Inject ServerName into Apache config if provided
if [[ -n "$HOSTNAME" ]]; then
    echo "ServerName $HOSTNAME" > /etc/apache2/conf-enabled/servername.conf
fi

DEPLOYMENT_MARKER_FILE="/var/run/.deriva-stack-deployed"
if [ ! -f "$DEPLOYMENT_MARKER_FILE" ]; then

    echo "🔧   Deploying Deriva stack..."
    export ENV PIP_NO_CACHE_DIR=yes

    # Configure Postgres user account and connection
    envsubst '${POSTGRES_HOST}' < /home/postgres/.bash_profile.in > /home/postgres/.bash_profile
    envsubst '${POSTGRES_HOST} ${POSTGRES_USER} ${POSTGRES_PASSWORD}' < /home/postgres/.pgpass.in > \
     /home/postgres/.pgpass
    chown postgres:postgres /home/postgres/.*
    chmod 0600 /home/postgres/.pgpass

    # Create DERIVA Postgres DB roles via postgres user
    sudo -iu postgres env \
     POSTGRES_ERMREST_PASSWORD=${POSTGRES_ERMREST_PASSWORD} \
     POSTGRES_HATRAC_PASSWORD=${POSTGRES_HATRAC_PASSWORD} \
     POSTGRES_CREDENZA_PASSWORD=${POSTGRES_CREDENZA_PASSWORD} \
     POSTGRES_WEBAUTHN_PASSWORD=${POSTGRES_WEBAUTHN_PASSWORD} \
     POSTGRES_DERIVA_PASSWORD=${POSTGRES_DERIVA_PASSWORD} \
     "create-db-roles.sh"

    # Configure ERMRest -> Postgres connection
    envsubst '${POSTGRES_HOST} ${ERMREST_CATALOG_CREATE_GROUP}' < /home/ermrest/ermrest_config.json.in > \
     /home/ermrest/ermrest_config.json
    envsubst '${POSTGRES_HOST}' < /home/ermrest/.bash_profile.in > /home/ermrest/.bash_profile
    envsubst '${POSTGRES_HOST} ${POSTGRES_ERMREST_PASSWORD}' < /home/ermrest/.pgpass.in > /home/ermrest/.pgpass
    chown ermrest /home/ermrest/.*
    chmod 0600 /home/ermrest/.pgpass

    # Configure Hatrac -> Postgres connection
    envsubst '${POSTGRES_HOST}' < /home/hatrac/hatrac_config.json.in > /home/hatrac/hatrac_config.json
    envsubst '${POSTGRES_HOST}' < /home/hatrac/.bash_profile.in > /home/hatrac/.bash_profile
    envsubst '${POSTGRES_HOST} ${POSTGRES_HATRAC_PASSWORD}' < /home/hatrac/.pgpass.in > /home/hatrac/.pgpass
    chown hatrac /home/hatrac/.*
    chmod 0600 /home/hatrac/.pgpass

    # Configure Credenza
    envsubst '${OKTA_HOST} ${HOSTNAME}' < /home/credenza/config/oidc_idp_profiles.json.in > \
     /home/credenza/config/oidc_idp_profiles.json
    envsubst '${OKTA_CLIENT_ID} ${OKTA_CLIENT_SECRET}' < /home/credenza/secrets/okta_client_secret.json.in > \
     /home/credenza/secrets/okta_client_secret.json
    su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='credenza'\"" | grep -q 1 \
     || su - postgres -c "createdb -O credenza credenza"

    # Configure Webauthn -> Postgres connection (temp until webauthn removed from build)
    envsubst '${POSTGRES_HOST} ${POSTGRES_WEBAUTHN_PASSWORD}' < /home/webauthn/webauthn2_config.json.in \
     > /home/webauthn/webauthn2_config.json

    # Deal with possible alternate ports in ClientSessionCachedProxy config
    sed -i -E "s/(\"session_host\"\s*:\s*\"localhost:)[0-9]+(\")/\1${APACHE_HTTPS_PORT}\2/" \
     /home/ermrest/ermrest_config.json
    sed -i -E "s/(\"session_host\"\s*:\s*\"localhost:)[0-9]+(\")/\1${APACHE_HTTPS_PORT}\2/" \
     /home/hatrac/hatrac_config.json
    isrd-stack-mgmt.sh deploy
    isrd_fixup_permissions /var/www

    # Configure Apache vhost ports
    envsubst '${APACHE_HTTPS_PORT}' < /etc/apache2/sites-available/default-ssl.conf.template \
     > /etc/apache2/sites-available/default-ssl.conf
    # Also need to replace Listen 80 and 443 lines in /etc/apache2/ports.conf to match vhosts entries
    sed -i  -e "s/^\s*Listen\s\+443\b/Listen ${APACHE_HTTPS_PORT}/" /etc/apache2/ports.conf
    a2ensite -q default-ssl

    # Generate and install a self-signed certificate and add it to the local trust store
    SYSTEM_CERT_PATH="/etc/ssl/certs/deriva.crt"
    SYSTEM_KEY_PATH="/etc/ssl/private/deriva.key"
    SYSTEM_CA_CERT_PATH="/usr/local/share/ca-certificates/deriva.crt"
    echo "🔧   Generating self-signed TLS certificate..."
    # Step 1: Generate RSA private key quietly
    openssl genrsa -out $SYSTEM_KEY_PATH 4096 2>/dev/null
    # Step 2: Generate self-signed cert
    openssl req -new -x509 \
      -key "$SYSTEM_KEY_PATH" \
      -out "$SYSTEM_CERT_PATH" \
      -days 365 \
      -subj "/CN=${HOSTNAME}" \
      -addext "subjectAltName=DNS:${HOSTNAME}" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=keyCertSign,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth"
    chmod 644 $SYSTEM_CERT_PATH
    chown root:root $SYSTEM_CERT_PATH
    chmod 600 $SYSTEM_KEY_PATH
    chown root:root $SYSTEM_KEY_PATH
    echo "✅   TLS certificate generated successfully."
    # # Step 3: add our self-signed fallback certificate so that internal SSL requests do not get rejected
    echo "⚙️   Installing self-signed certificate to local trust store..."
    cp $SYSTEM_CERT_PATH $SYSTEM_CA_CERT_PATH
    update-ca-certificates

#    # Disable legacy mod_webauthn
#    a2dismod -q webauthn
#    rm -f /etc/apache2/conf.d/webauthn.conf

    touch "$DEPLOYMENT_MARKER_FILE"
    echo "✅   Deriva software deployment complete."
else
    echo "✅   Skipping Deriva software deployment steps; already installed."
fi

TESTENV_MARKER_FILE="/var/www/.testenv-deployed"
if [ ! -f "$TESTENV_MARKER_FILE" ]; then
    if [[ "$INCLUDE_TESTDB" == "true" ]]; then
      echo "🔧   Restoring test catalog..."
      dbname="${TEST_DBNAME:-"_ermrest_catalog_1"}"
      isrd_restore_db ermrest ermrest "${dbname}" "/var/tmp/${dbname}.sql.gz"
      isrd_insert_ermrest_registry "${dbname}" "${POSTGRES_HOST}"
    fi
    touch "$TESTENV_MARKER_FILE"
    echo "✅   Test environment deployment complete."
else
    echo "✅   Skipping test environment deployment steps; already installed."
fi

# Suppress cert verify warnings for 'localhost', generated by inter-service communication when cert verify is disabled
export PYTHONWARNINGS="ignore:Unverified HTTPS request is being made to host 'localhost'."

exec apache2ctl -D FOREGROUND


