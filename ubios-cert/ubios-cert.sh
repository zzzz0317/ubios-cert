#!/bin/sh

set -e

# Load environment variables
. /mnt/data/ubios-cert/ubios-cert.env

# Setup variables for later for those who want to tinker around
PODMAN_VOLUMES="-v ${ACMESH_ROOT}:/acme.sh"
PODMAN_ENV="${DNS_API_ENV}"
PODMAN_IMAGE="neilpang/acme.sh"
PODMAN_LOGFILE="--log /acme.sh/acme.sh.log"
PODMAN_LOGLEVEL="--log-level 1" # default is 1, can be increased to 2
PODMAN_LOG="${PODMAN_LOGFILE} ${PODMAN_LOGLEVEL}"

NEW_CERT=""

deploy_cert() {
	# Re-write CERT_NAME if it is a wildcard cert. Replace * with _
	ACME_CERT_NAME=${CERT_NAME/\*/_}
	if [ "$(find -L "${ACMESH_ROOT}" -type f -name "${ACME_CERT_NAME}".cer -mmin -5)" ]; then
		echo "New certificate was generated, time to deploy it"
		# Controller certificate
		cp -f ${ACMESH_ROOT}/${ACME_CERT_NAME}/${ACME_CERT_NAME}.cer ${UBIOS_CERT_PATH}/unifi-core.crt
		cp -f ${ACMESH_ROOT}/${ACME_CERT_NAME}/${ACME_CERT_NAME}.key ${UBIOS_CERT_PATH}/unifi-core.key
		chmod 644 ${UBIOS_CERT_PATH}/unifi-core.*
		NEW_CERT="yes"
	else
		echo "No new certificate was found, exiting without restart"
	fi
}

add_captive(){
	 # Import the certificate for the captive portal
         if [ "$ENABLE_CAPTIVE" == "yes" ]; then
         	podman exec -it unifi-os ${CERT_IMPORT_CMD} ${UNIFIOS_CERT_PATH}/unifi-core.key ${UNIFIOS_CERT_PATH}/unifi-core.crt
         fi
}

remove_old_log(){
	# Trash the previous logfile
	if [ -f "${UBIOS_CERT_ROOT}/acme.sh/acme.sh.log" ]; then
		rm "${UBIOS_CERT_ROOT}/acme.sh/acme.sh.log"
		echo "Removed old logfile"
	fi
}

# Support multiple certificate SANs
for DOMAIN in $(echo $CERT_HOSTS | tr "," "\n"); do
	if [ -z "$CERT_NAME" ]; then
		CERT_NAME=$DOMAIN
	fi
	PODMAN_DOMAINS="${PODMAN_DOMAINS} -d ${DOMAIN}"
done

PODMAN_CMD="podman run --env-file=${UBIOS_CERT_ROOT}/ubios-cert.env -it --net=host --rm ${PODMAN_VOLUMES} ${PODMAN_ENV} ${PODMAN_IMAGE}"

# Setup persistent on_boot.d trigger
ON_BOOT_DIR='/mnt/data/on_boot.d'
ON_BOOT_FILE='99-ubios-cert.sh'
if [ -d "${ON_BOOT_DIR}" ] && [ ! -f "${ON_BOOT_DIR}/${ON_BOOT_FILE}" ]; then
	cp "${UBIOS_CERT_ROOT}/on_boot.d/${ON_BOOT_FILE}" "${ON_BOOT_DIR}/${ON_BOOT_FILE}"
	chmod 755 ${ON_BOOT_DIR}/${ON_BOOT_FILE}
	echo "Restored 'on_boot.d' trigger"
fi

# Setup nightly cron job
CRON_FILE='/etc/cron.d/ubios-cert'
if [ ! -f "${CRON_FILE}" ]; then
	echo "0 6 * * * sh ${UBIOS_CERT_ROOT}/ubios-cert.sh renew" >${CRON_FILE}
	chmod 644 ${CRON_FILE}
	/etc/init.d/crond reload ${CRON_FILE}
	echo "Restored cron file"
fi

# confirm if 'account.conf' exists and can only be accessed by owner (nobody / nogroup)
if [ -f "${ACMESH_ROOT}/account.conf" ]; then
	if [ "$(stat -c '%a' "${ACMESH_ROOT}/account.conf")" != "600" ]; then
		chmod 600 ${ACMESH_ROOT}/account.conf
	fi
fi

case $1 in
initial)
	# Create acme.sh directory so the container can write to it - owner "nobody"
	if [ "$(stat -c '%u:%g' "${ACMESH_ROOT}")" != "65534:65534" ]; then
		mkdir "${ACMESH_ROOT}"
		chown 65534:65534 "${ACMESH_ROOT}"
	fi

	echo "Attempting initial certificate generation"
	remove_old_log
	${PODMAN_CMD} --issue ${PODMAN_DOMAINS} --dns ${DNS_API_PROVIDER} --keylength 2048 ${PODMAN_LOG} && add_captive && unifi-os restart
	;;
renew)
	echo "Attempting certificate renewal"
	remove_old_log
	${PODMAN_CMD} --renew ${PODMAN_DOMAINS} --dns ${DNS_API_PROVIDER} --keylength 2048 ${PODMAN_LOG} && deploy_cert
	if [ "${NEW_CERT}" = "yes" ]; then
		add_captive && unifi-os restart
	fi
	;;
bootrenew)
	echo "Attempting certificate renewal after boot"
	remove_old_log
	${PODMAN_CMD} --renew ${PODMAN_DOMAINS} --dns ${DNS_API_PROVIDER} --keylength 2048 ${PODMAN_LOGFILE} ${PODMAN_LOGLEVEL} && deploy_cert && add_captive && unifi-os restart
	;;
testdeploy)
	echo "Attempting to deploy certificate"
	deploy_cert
	;;
cleanup)
	if [ -f "${CRON_FILE}" ]; then
		rm "${CRON_FILE}"
		echo "Removed cron file"
	fi

	if [ -d "${ON_BOOT_DIR}" ] && [ -f "${ON_BOOT_DIR}/${ON_BOOT_FILE}" ]; then
		rm "${ON_BOOT_DIR}/${ON_BOOT_FILE}"
		echo "Removed on_boot.d trigger"
	fi

	if [ -f "${ACMESH_ROOT}/account.conf" ]; then
		remove_old_log
		echo "Executing: ${PODMAN_CMD} --remove ${PODMAN_DOMAINS}"
		${PODMAN_CMD} --remove ${PODMAN_DOMAINS}
		echo "Removed certificates from LE account"

		echo "Executing: ${PODMAN_CMD} --deactivate-account"
		${PODMAN_CMD} --deactivate-account
		echo "Deactivated LE account"
	fi
	;;
esac