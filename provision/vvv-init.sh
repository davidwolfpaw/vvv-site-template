#!/usr/bin/env bash
# Provision WordPress Stable

set -eo pipefail

echo " * Custom site template provisioner ${VVV_SITE_NAME} - downloads and installs a copy of WP stable for testing, building client sites, etc"

# fetch the first host as the primary domain. If none is available, generate a default using the site name
DOMAIN=$(get_primary_host "${VVV_SITE_NAME}".test)
SITE_TITLE=$(get_config_value 'site_title' "${DOMAIN}")
WP_VERSION=$(get_config_value 'wp_version' 'latest')
WP_LOCALE=$(get_config_value 'locale' 'en_US')
WP_TYPE=$(get_config_value 'wp_type' "single")
DB_NAME=$(get_config_value 'db_name' "${VVV_SITE_NAME}")
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*]/}
DB_PREFIX=$(get_config_value 'db_prefix' 'wp_')

# Assign custom values to constants
ACFPROLICENSE=`get_config_value 'acfprolicense'`
WORDPRESSAPIKEY=`get_config_value 'wordpressapikey'`
RGGFORMSKEY=`get_config_value 'rggformskey'`

# Make a database, if we don't already have one
setup_database() {
  echo -e " * Creating database '${DB_NAME}' (if it's not already there)"
  mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
  echo -e " * Granting the wp user priviledges to the '${DB_NAME}' database"
  mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO wp@localhost IDENTIFIED BY 'wp';"
  echo -e " * DB operations done."
}

setup_nginx_folders() {
  echo " * Setting up the log subfolder for Nginx logs"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-error.log"
  noroot touch "${VVV_PATH_TO_SITE}/log/nginx-access.log"
  echo " * Creating public_html folder if it doesn't exist already"
  noroot mkdir -p "${VVV_PATH_TO_SITE}/public_html"
}

install_plugins() {
  WP_PLUGINS=$(get_config_value 'install_plugins' '')
  if [ ! -z "${WP_PLUGINS}" ]; then
    for plugin in ${WP_PLUGINS//- /$'\n'}; do
        echo " * Installing/activating plugin: '${plugin}'"
        noroot wp plugin install "${plugin}" --activate
    done
  fi
}

install_themes() {
  WP_THEMES=$(get_config_value 'install_themes' '')
  if [ ! -z "${WP_THEMES}" ]; then
      for theme in ${WP_THEMES//- /$'\n'}; do
        echo " * Installing theme: '${theme}'"
        noroot wp theme install "${theme}"
      done
  fi
}

copy_nginx_configs() {
  echo " * Copying the sites Nginx config template"
  if [ -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" ]; then
    echo " * A vvv-nginx-custom.conf file was found"
    cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-custom.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    echo " * Using the default vvv-nginx-default.conf, to customize, create a vvv-nginx-custom.conf"
    cp -f "${VVV_PATH_TO_SITE}/provision/vvv-nginx-default.conf" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi

  LIVE_URL=$(get_config_value 'live_url' '')
  if [ ! -z "$LIVE_URL" ]; then
    echo " * Adding support for Live URL redirects to NGINX of the website's media"
    # replace potential protocols, and remove trailing slashes
    LIVE_URL=$(echo "${LIVE_URL}" | sed 's|https://||' | sed 's|http://||'  | sed 's:/*$::')

    redirect_config=$((cat <<END_HEREDOC
if (!-e \$request_filename) {
  rewrite ^/[_0-9a-zA-Z-]+(/wp-content/uploads/.*) \$1;
}
if (!-e \$request_filename) {
  rewrite ^/wp-content/uploads/(.*)\$ \$scheme://${LIVE_URL}/wp-content/uploads/\$1 redirect;
}
END_HEREDOC

    ) |
    # pipe and escape new lines of the HEREDOC for usage in sed
    sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n\\1/g'
    )

    sed -i -e "s|\(.*\){{LIVE_URL}}|\1${redirect_config}|" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  else
    sed -i "s#{{LIVE_URL}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
  fi
}

setup_wp_config_constants(){
  set +e
  shyaml get-values-0 -q "sites.${VVV_SITE_NAME}.custom.wpconfig_constants" < "${VVV_CONFIG}" |
  while IFS='' read -r -d '' key &&
        IFS='' read -r -d '' value; do
      lower_value=$(echo "${value}" | awk '{print tolower($0)}')
      echo " * Adding constant '${key}' with value '${value}' to wp-config.php"
      if [ "${lower_value}" == "true" ] || [ "${lower_value}" == "false" ] || [[ "${lower_value}" =~ ^[+-]?[0-9]*$ ]] || [[ "${lower_value}" =~ ^[+-]?[0-9]+\.?[0-9]*$ ]]; then
        noroot wp config set "${key}" "${value}" --raw
      else
        noroot wp config set "${key}" "${value}"
      fi
  done
  set -e
}

restore_db_backup() {
  echo " * Found a database backup at ${1}. Restoring the site"
  noroot wp config set DB_USER "wp"
  noroot wp config set DB_PASSWORD "wp"
  noroot wp config set DB_HOST "localhost"
  noroot wp config set DB_NAME "${DB_NAME}"
  noroot wp config set table_prefix "${DB_PREFIX}"
  noroot wp db import "${1}"
  echo " * Installed database backup"
}

download_wordpress() {
  # Install and configure the latest stable version of WordPress
  echo " * Downloading WordPress version '${2}' locale: '${3}'"
  noroot wp core download --locale="${3}" --version="${2}" --path="${1}"
}

initial_wpconfig() {
  echo " * Setting up wp-config.php"
  noroot wp core config --dbname="${DB_NAME}" --dbprefix="${DB_PREFIX}" --dbuser=wp --dbpass=wp  --extra-php <<PHP
define( 'WP_DEBUG', true );
define( 'SCRIPT_DEBUG', true );
define( 'WP_CACHE', false );
PHP
}

install_wp() {
  echo " * Installing WordPress"
  ADMIN_USER=$(get_config_value 'admin_user' "admin")
  ADMIN_PASSWORD=$(get_config_value 'admin_password' "password")
  ADMIN_EMAIL=$(get_config_value 'admin_email' "admin@local.test")

  echo " * Installing using wp core install --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\" --path=\"${VVV_PATH_TO_SITE}/public_html\""
  noroot wp core install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
  echo " * WordPress was installed, with the username '${ADMIN_USER}', and the password '${ADMIN_PASSWORD}' at '${ADMIN_EMAIL}'"

  if [ "${WP_TYPE}" = "subdomain" ]; then
    echo " * Running Multisite install using wp core multisite-install --subdomains --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\" --path=\"${VVV_PATH_TO_SITE}/public_html\""
    noroot wp core multisite-install --subdomains --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * Multisite install complete"
  elif [ "${WP_TYPE}" = "subdirectory" ]; then
    echo " * Running Multisite install using wp core ${INSTALL_COMMAND} --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\" --path=\"${VVV_PATH_TO_SITE}/public_html\""
    noroot wp core multisite-install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * Multisite install complete"
  fi

  DELETE_DEFAULT_PLUGINS=$(get_config_value 'delete_default_plugins' '')
  if [ ! -z "${DELETE_DEFAULT_PLUGINS}" ]; then
    echo " * Deleting the default plugins akismet and hello dolly"
    noroot wp plugin delete akismet
    noroot wp plugin delete hello
  fi

  DELETE_DEFAULT_THEMES=$(get_config_value 'delete_default_themes' '')
  if [ ! -z "${DELETE_DEFAULT_THEMES}" ]; then
    echo " * Deleting the default themes except the latest"
    noroot wp theme delete twentyseventeen
    noroot wp theme delete twentynineteen
  fi

  INSTALL_TEST_CONTENT=$(get_config_value 'install_test_content' "")
  if [ ! -z "${INSTALL_TEST_CONTENT}" ]; then
    echo " * Downloading test content from github.com/poststatus/wptest/master/wptest.xml"
    curl -s https://raw.githubusercontent.com/poststatus/wptest/master/wptest.xml > import.xml
    echo " * Installing the wordpress-importer"
    noroot wp plugin install wordpress-importer
    echo " * Activating the wordpress-importer"
    noroot wp plugin activate wordpress-importer
    echo " * Importing test data"
    noroot wp import import.xml --authors=create
    echo " * Cleaning up import.xml"
    rm import.xml
    echo " * Test content installed"
  fi

  INITIAL_BASE_SETUP=$(get_config_value 'initial_base_setup' "")
  if [ ! -z "${INITIAL_BASE_SETUP}" ]; then
    # install the themes and plugins that we do want
    noroot wp theme install https://orangeblossommedia.com/obm/tools/genesis.3.3.3.zip --activate
    noroot wp plugin install genesis-simple-edits
    noroot wp plugin install https://orangeblossommedia.com/obm/tools/advanced-custom-fields-pro.zip --activate
    noroot wp plugin install https://orangeblossommedia.com/obm/tools/gravityforms_2.4.21.3.zip --activate
    # # delete sample post
    # noroot wp post delete "$(noroot wp post list --post_type=post --posts_per_page=1 --post_status=publish --postname="hello-world" --field=ID --format=ids)" --force
    # # delete sample page, and create homepage
    # noroot wp post delete "$(noroot wp post list --post_type=page --posts_per_page=1 --post_status=publish --pagename="sample-page" --field=ID --format=ids)" --force
    # Add a comma separated list of pages
    allpages="Home,About,Contact,Blog"
    # create all of the pages
    IFS=","
    for page in $allpages
    do
      noroot wp post create --post_type=page --post_status=publish --post_author="$(noroot wp user get $wpuser --field=ID)" --post_title="$(echo $page | sed -e 's/^ *//' -e 's/ *$//')"
    done
    # set page as front page
    noroot wp option update show_on_front 'page'
    # set "Home" to be the new page
    noroot wp option update page_on_front "$(noroot wp post list --post_type=page --post_status=publish --posts_per_page=1 --pagename=home --field=ID)"
    # set "Blog" to be the new blogpage
    noroot wp option update page_for_posts "$(noroot wp post list --post_type=page --post_status=publish --posts_per_page=1 --pagename=blog --field=ID)"
    # Create a navigation bar
    noroot wp menu create "Main\ Navigation"
    # Add pages to navigation
    IFS=" "
    for pageid in $(noroot wp post list --order="ASC" --orderby="date" --post_type=page --post_status=publish --posts_per_page=-1 --field=ID --format=ids);
    do
      noroot wp menu item add-post main-navigation "$pageid"
    done
    # Assign navigation to primary location
    noroot wp menu location assign main-navigation primary

    # Remove default widgets from sidebars
    # widgetsheaderright=$(noroot wp widget list header-right --format=ids)
    # noroot wp widget delete $widgetsheaderright
    # widgetsprimary=$(noroot wp widget list sidebar --format=ids)
    # noroot wp widget delete $widgetsprimary
    # widgetssecondary=$(noroot wp widget list sidebar-alt --format=ids)
    # noroot wp widget delete $widgetssecondary

    # Create a category called "News" and set it as default
    noroot wp term create category News
    noroot wp option update default_category "$(noroot wp term list category --name=news --field=id)"
    # update and add general options
    noroot wp option update date_format 'j F Y'
    noroot wp option update links_updated_date_format 'F j, Y g:i a'
    noroot wp option update timezone_string 'America/New_York'
    noroot wp option update permalink_structure '/%postname%/'
    noroot wp option add rg_gforms_enable_akismet '1'
    noroot wp option add rg_gforms_currency 'USD'
    noroot wp option add acf_pro_license $ACFPROLICENSE
    noroot wp option add wordpress_api_key $WORDPRESSAPIKEY
    noroot wp option add rg_gforms_key $RGGFORMSKEY
    echo " * Build defaults initiated"
  fi
}

update_wp() {
  if [[ $(noroot wp core version) > "${WP_VERSION}" ]]; then
    echo " * Installing an older version '${WP_VERSION}' of WordPress"
    noroot wp core update --version="${WP_VERSION}" --force
  else
    echo " * Updating WordPress '${WP_VERSION}'"
    noroot wp core update --version="${WP_VERSION}"
  fi
}

setup_database
setup_nginx_folders

cd "${VVV_PATH_TO_SITE}/public_html"



if [ "${WP_TYPE}" == "none" ]; then
  echo " * wp_type was set to none, provisioning WP was skipped, moving to Nginx configs"
else
  echo " * Install type is '${WP_TYPE}'"
  # Install and configure the latest stable version of WordPress
  if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-load.php" ]]; then
    download_wordpress "${VVV_PATH_TO_SITE}/public_html" "${WP_VERSION}" "${WP_LOCALE}"
  fi

  if [[ ! -f "${VVV_PATH_TO_SITE}/public_html/wp-config.php" ]]; then
    initial_wpconfig
  fi

  if ! $(noroot wp core is-installed ); then
    echo " * WordPress is present but isn't installed to the database, checking for SQL dumps in wp-content/database.sql or the main backup folder."
    if [ -f "${VVV_PATH_TO_SITE}/public_html/wp-content/database.sql" ]; then
      restore_db_backup "${VVV_PATH_TO_SITE}/public_html/wp-content/database.sql"
    elif [ -f "/srv/database/backups/${VVV_SITE_NAME}.sql" ]; then
      restore_db_backup "/srv/database/backups/${VVV_SITE_NAME}.sql"
    else
      install_wp
    fi
  else
    update_wp
  fi
fi

copy_nginx_configs
setup_wp_config_constants
install_plugins
install_themes

echo " * Site Template provisioner script completed for ${VVV_SITE_NAME}"
