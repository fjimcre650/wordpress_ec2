#!/bin/bash
#
# Instalación automática de LAMP + 2 sitios WordPress en una instancia EC2 (Ubuntu)
# Versión corregida y mejorada.
#
# CAMBIOS PRINCIPALES respecto al script original (ver detalle al final del fichero):
#   - Se quita mysql_secure_installation (interactivo -> colgaba el script) y se
#     sustituye por el hardening equivalente en SQL.
#   - Se corrige la creación de carpetas wordpress/wordpress_pruebas (el original
#     intentaba ejecutar "/var/www/html/mkdir" como comando).
#   - Se corrige la copia de los ficheros de WordPress (antes copiaba desde una
#     ruta relativa vacía).
#   - Se genera wp-config.php automáticamente con credenciales reales + claves de
#     seguridad (salts) reales, en el momento correcto (antes el script intentaba
#     editar un wp-config.php que todavía no existía).
#   - Se detecta la versión de PHP instalada en vez de asumir 8.2.
#   - Se quita la línea con el placeholder "php-<nombre_de_la_extension>".
#   - Se activa mod_rewrite y AllowOverride All (necesario para permalinks).
#   - Se usa el endpoint de metadatos de EC2 (IMDSv2) para la IP pública, con
#     fallback a un servicio externo.
#   - set -e + log en fichero para detectar fallos reales en vez de seguir a ciegas.

set -eo pipefail

#############################################
# 0. CONFIGURACIÓN — AJUSTA ESTOS VALORES
#############################################
DB_ROOT_PASSWORD="CambiaEstaPassword_root!"
DB_NAME="wordpress"
DB_NAME_TEST="wordpress_pruebas"
DB_USER="wp_user"
DB_USER_PASSWORD="CambiaEstaPassword_user!"

UPLOAD_MAX_FILESIZE="1024M"
POST_MAX_SIZE="1024M"
PHP_MEMORY_LIMIT="256M"
MAX_EXECUTION_TIME="300"
MAX_INPUT_TIME="300"

SWAP_SIZE_GB=8

# Extensiones PHP habituales para WordPress (edita la lista si necesitas otras)
PHP_EXTRA_EXTENSIONS=(php-gd php-mbstring php-curl php-xml php-zip php-imagick php-intl)

#############################################

if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script con sudo: sudo $0"
  exit 1
fi

# Log completo a fichero, además de la pantalla, para poder depurar luego
exec > >(tee -a /var/log/wp_setup.log) 2>&1
trap 'echo "❌ Error en la línea $LINENO. Revisa /var/log/wp_setup.log"; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # evita el diálogo "qué servicios reiniciar" de needrestart

echo "====================================================="
echo "1. ACTUALIZANDO EL SISTEMA"
echo "====================================================="
apt update && apt -y upgrade

echo "====================================================="
echo "2. INSTALANDO APACHE, MYSQL, PHP Y EXTENSIONES"
echo "====================================================="
apt -y install apache2 mysql-server php libapache2-mod-php php-mysql "${PHP_EXTRA_EXTENSIONS[@]}"

systemctl enable --now apache2
systemctl enable --now mysql

echo "====================================================="
echo "3. CONFIGURANDO MYSQL (usuarios, bases de datos, hardening)"
echo "====================================================="
# Sustituye a mysql_secure_installation (que es interactivo y bloquearía el script):
# - cambia el método de autenticación de root y le pone contraseña
# - elimina usuarios anónimos
# - elimina accesos remotos de root
# - elimina la base de datos "test"
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${DB_ROOT_PASSWORD}';

DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE DATABASE IF NOT EXISTS ${DB_NAME_TEST};

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_USER_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_NAME_TEST}.* TO '${DB_USER}'@'localhost';

FLUSH PRIVILEGES;
EOF
echo "¡Configuración de base de datos completada con éxito!"

echo "====================================================="
echo "4. DESCARGANDO Y DESPLEGANDO WORDPRESS (2 sitios)"
echo "====================================================="
WORK_DIR="/home/ubuntu/wp_setup_tmp"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

curl -fsSL -o wordpress.tar.gz https://wordpress.org/latest.tar.gz
tar -xzf wordpress.tar.gz   # crea $WORK_DIR/wordpress

mkdir -p /var/www/html/wordpress /var/www/html/wordpress_pruebas
cp -R "$WORK_DIR"/wordpress/. /var/www/html/wordpress/
cp -R "$WORK_DIR"/wordpress/. /var/www/html/wordpress_pruebas/

# Función para generar wp-config.php con credenciales reales y claves de seguridad
# reales (en vez del placeholder "put your unique phrase here").
configurar_wp_config() {
  local wpdir="$1" dbname="$2" dbuser="$3" dbpass="$4"
  local wpconfig="$wpdir/wp-config.php"

  if [ -f "$wpconfig" ]; then
    echo "  -> wp-config.php ya existe en $wpdir, no se modifica."
    return 0
  fi
  if [ ! -f "$wpdir/wp-config-sample.php" ]; then
    echo "  -> ⚠️  No se encontró wp-config-sample.php en $wpdir"
    return 1
  fi

  cp "$wpdir/wp-config-sample.php" "$wpconfig"
  sed -i "s/database_name_here/${dbname}/" "$wpconfig"
  sed -i "s/username_here/${dbuser}/" "$wpconfig"
  sed -i "s/password_here/${dbpass}/" "$wpconfig"

  # Quita las 8 claves de ejemplo; se sustituyen por unas reales más abajo
  sed -i "/define( *'AUTH_KEY'/,/define( *'NONCE_SALT'/d" "$wpconfig"

  local salts
  salts=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ || true)

  local extra
  extra=$(cat <<BLOCK
${salts}

@ini_set( 'upload_max_filesize', '${UPLOAD_MAX_FILESIZE}' );
@ini_set( 'post_max_size', '${POST_MAX_SIZE}' );
@ini_set( 'memory_limit', '${PHP_MEMORY_LIMIT}' );
@ini_set( 'max_execution_time', '${MAX_EXECUTION_TIME}' );
@ini_set( 'max_input_time', '${MAX_INPUT_TIME}' );
BLOCK
)

  awk -v extra="$extra" '/stop editing/ { print extra; print "" } { print }' "$wpconfig" > "${wpconfig}.tmp"
  mv "${wpconfig}.tmp" "$wpconfig"
  echo "  -> wp-config.php generado correctamente en $wpdir"
}

configurar_wp_config /var/www/html/wordpress "$DB_NAME" "$DB_USER" "$DB_USER_PASSWORD"
configurar_wp_config /var/www/html/wordpress_pruebas "$DB_NAME_TEST" "$DB_USER" "$DB_USER_PASSWORD"

# Permisos para Apache (www-data)
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# Limpieza de los ficheros temporales de descarga
cd ~
rm -rf "$WORK_DIR"

echo "====================================================="
echo "5. AJUSTANDO LÍMITES DE PHP (subida de archivos, memoria, etc.)"
echo "====================================================="
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
RUTA_INI="/etc/php/${PHP_VERSION}/apache2/php.ini"

if [ ! -f "$RUTA_INI" ]; then
  echo "Error: no se encontró $RUTA_INI (versión de PHP detectada: $PHP_VERSION)"
  exit 1
fi

cp "$RUTA_INI" "${RUTA_INI}.bak"

actualizar_parametro() {
  local clave=$1 valor=$2
  if grep -qE "^[; ]*${clave}[ ]*=" "$RUTA_INI"; then
    sed -i -E "s|^[; ]*(${clave})[ ]*=.*|\1 = ${valor}|" "$RUTA_INI"
  else
    echo "${clave} = ${valor}" >> "$RUTA_INI"
  fi
}

actualizar_parametro "upload_max_filesize" "$UPLOAD_MAX_FILESIZE"
actualizar_parametro "post_max_size" "$POST_MAX_SIZE"
actualizar_parametro "memory_limit" "$PHP_MEMORY_LIMIT"
actualizar_parametro "max_execution_time" "$MAX_EXECUTION_TIME"
actualizar_parametro "max_input_time" "$MAX_INPUT_TIME"

echo "¡Valores php.ini actualizados con éxito! (PHP $PHP_VERSION)"

echo "====================================================="
echo "6. HABILITANDO MOD_REWRITE Y PERMALINKS (.htaccess)"
echo "====================================================="
a2enmod rewrite
# Por defecto Apache trae AllowOverride None para /var/www, lo que impide que
# funcionen los permalinks "bonitos" de WordPress (.htaccess). Lo cambiamos a All.
if grep -q "AllowOverride None" /etc/apache2/apache2.conf; then
  sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
fi
systemctl restart apache2

echo "====================================================="
echo "7. CONFIGURANDO ESPACIO DE INTERCAMBIO (SWAP ${SWAP_SIZE_GB}GB)"
echo "====================================================="
if swapon --show | grep -q "/swapfile"; then
  echo "El archivo swap ya existe y está activo. Saltando..."
else
  echo "Creando archivo swap de ${SWAP_SIZE_GB}GB..."
  if ! fallocate -l "${SWAP_SIZE_GB}G" /swapfile 2>/dev/null; then
    echo "fallocate falló. Intentando con dd (esto puede tardar un poco)..."
    dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Configuración añadida a /etc/fstab de forma permanente."
  fi
fi

echo "====================================================="
echo "8. RESUMEN"
echo "====================================================="

# IP pública: usamos primero el servicio de metadatos de EC2 (IMDSv2), y si por
# lo que sea no responde, recurrimos a un servicio externo como respaldo.
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
IP=""
if [ -n "$TOKEN" ]; then
  IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
fi
if [ -z "$IP" ]; then
  IP=$(curl -s https://ifconfig.me || true)
fi

echo "✅ Instalación completada."
echo "➡️  WordPress       - BD: ${DB_NAME}      | Usuario: ${DB_USER} | Contraseña: (la que definiste)"
echo -e "    🌐 http://${IP}/wordpress\n"
echo "➡️  WordPress PRUEBAS - BD: ${DB_NAME_TEST} | Usuario: ${DB_USER} | Contraseña: (la que definiste)"
echo -e "    🌐 http://${IP}/wordpress_pruebas\n"
echo "Recuerda: las bases de datos y wp-config.php ya están configurados,"
echo "solo te falta completar el asistente de instalación de WordPress en el navegador"
echo "(título del sitio, usuario admin, etc.)."

if [ -f /var/run/reboot-required ]; then
  echo
  echo "⚠️  El sistema indica que conviene reiniciar tras las actualizaciones."
  echo "    Puedes hacerlo más tarde con: sudo reboot"
fi