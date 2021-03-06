#!/bin/bash

#Inialize Postgres
echo "Initializing Postgres"

POSTGRES_COMMAND="postgres"

set -Eeo pipefail
# TODO swap to -Eeuo pipefail above (after handling all potentially-unset variables)

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

if [ "${1:0:1}" = '-' ]; then
	set -- postgres "$POSTGRES_COMMAND"
fi

# allow the container to be started with `--user`
if [ "$(id -u)" = '0' ]; then
	mkdir -p "$PGDATA"
	chown -R postgres "$PGDATA"
	chmod 700 "$PGDATA"

	mkdir -p /var/run/postgresql
	chown -R postgres /var/run/postgresql
	chmod 775 /var/run/postgresql

	# Create the transaction log directory before initdb is run (below) so the directory is owned by the correct user
	if [ "$POSTGRES_INITDB_WALDIR" ]; then
		mkdir -p "$POSTGRES_INITDB_WALDIR"
		chown -R postgres "$POSTGRES_INITDB_WALDIR"
		chmod 700 "$POSTGRES_INITDB_WALDIR"
	fi

	exec gosu postgres "$BASH_SOURCE" "$POSTGRES_COMMAND"
fi


mkdir -p "$PGDATA"
chown -R "$(id -u)" "$PGDATA" 2>/dev/null || :
chmod 700 "$PGDATA" 2>/dev/null || :

# look specifically for PG_VERSION, as it is expected in the DB dir
if [ ! -s "$PGDATA/PG_VERSION" ]; then
	# "initdb" is particular about the current user existing in "/etc/passwd", so we use "nss_wrapper" to fake that if necessary
	# see https://github.com/docker-library/postgres/pull/253, https://github.com/docker-library/postgres/issues/359, https://cwrap.org/nss_wrapper.html
	if ! getent passwd "$(id -u)" &> /dev/null && [ -e /usr/lib/libnss_wrapper.so ]; then
		export LD_PRELOAD='/usr/lib/libnss_wrapper.so'
		export NSS_WRAPPER_PASSWD="$(mktemp)"
		export NSS_WRAPPER_GROUP="$(mktemp)"
		echo "postgres:x:$(id -u):$(id -g):PostgreSQL:$PGDATA:/bin/false" > "$NSS_WRAPPER_PASSWD"
		echo "postgres:x:$(id -g):" > "$NSS_WRAPPER_GROUP"
	fi

	file_env 'POSTGRES_INITDB_ARGS'
	if [ "$POSTGRES_INITDB_WALDIR" ]; then
		export POSTGRES_INITDB_ARGS="$POSTGRES_INITDB_ARGS --waldir $POSTGRES_INITDB_WALDIR"
	fi
	eval "initdb --username=postgres $POSTGRES_INITDB_ARGS"

	# unset/cleanup "nss_wrapper" bits
	if [ "${LD_PRELOAD:-}" = '/usr/lib/libnss_wrapper.so' ]; then
		rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP"
		unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
	fi

	# check password first so we can output the warning before postgres
	# messes it up
	file_env 'POSTGRES_MAIN_PASSWORD'
	if [ "$POSTGRES_MAIN_PASSWORD" ]; then
		pass="PASSWORD '$POSTGRES_MAIN_PASSWORD'"
		authMethod=md5
	else
		# The - option suppresses leading tabs but *not* spaces. :)
		cat >&2 <<-'EOWARN'
			****************************************************
			WARNING: No password has been set for the database.
			         This will allow anyone with access to the
			         Postgres port to access your database. In
			         Docker's default configuration, this is
			         effectively any other container on the same
			         system.
			         Use "-e POSTGRES_MAIN_PASSWORD=password" to set
			         it in "docker run".
			****************************************************
		EOWARN

		pass=
		authMethod=trust
	fi

	{
		echo
		echo "host all all all $authMethod"
	} >> "$PGDATA/pg_hba.conf"

	# internal start of server in order to allow set-up using psql-client
	# does not listen on external TCP/IP and waits until start finishes
	PGUSER="${PGUSER:-postgres}" \
	pg_ctl -D "$PGDATA" \
		-o "-c listen_addresses=''" \
		-w start

	file_env 'POSTGRES_USER' 'postgres'
	file_env 'POSTGRES_DB' "$POSTGRES_USER"

	psql=( psql -v ON_ERROR_STOP=1 )

	if [ "$POSTGRES_DB" != 'postgres' ]; then
		"${psql[@]}" --username postgres <<-EOSQL
			CREATE DATABASE "$POSTGRES_DB" ;
		EOSQL
		echo
	fi

	if [ "$POSTGRES_USER" = 'postgres' ]; then
		op='ALTER'
	else
		op='CREATE'
	fi
	"${psql[@]}" --username postgres <<-EOSQL
		$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
	EOSQL
	echo

	psql+=( --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" )

	echo
	for f in /docker-entrypoint-initdb.d/*; do
		case "$f" in
			*.sh)     echo "$0: running $f"; . "$f" ;;
			*.sql)    echo "$0: running $f"; "${psql[@]}" -f "$f"; echo ;;
			*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
			*)        echo "$0: ignoring $f" ;;
		esac
		echo
	done

	"${psql[@]}" --username postgres <<-EOSQL
		CREATE DATABASE "$POSTGRES_OPENSRP_DATABASE";
	EOSQL
	echo

	"${psql[@]}" --username postgres <<-EOSQL
		CREATE USER "$POSTGRES_OPENSRP_USER" WITH SUPERUSER ENCRYPTED PASSWORD '$POSTGRES_OPENSRP_PASSWORD';
	EOSQL
	echo

	"${psql[@]}" --username postgres <<-EOSQL
		GRANT ALL PRIVILEGES ON DATABASE "$POSTGRES_OPENSRP_DATABASE" TO "$POSTGRES_OPENSRP_USER";
	EOSQL
	echo

	PGUSER="${PGUSER:-postgres}" \
	pg_ctl -D "$PGDATA" -m fast -w stop

	echo
	echo 'PostgreSQL init process complete; ready for start up.'
	echo

	echo  'Starting Postgres to run migrations'
	pg_ctl -D $PGDATA -w start
	echo "Starting migrations"
	/opt/mybatis-migrations-3.3.4/bin/migrate up --path=/migrate

	if [ ! -f /etc/migrations/.postgres_migrations_complete ]; then
		POSTGRES_HOST=localhost
		if [[ -n $DEMO_DATA_TAG ]];then
			wget --quiet --no-cookies https://s3-eu-west-1.amazonaws.com/opensrp-stage/demo/${DEMO_DATA_TAG}/sql/opensrp.sql.gz -O /tmp/opensrp.sql.gz
			if [[ -f /tmp/opensrp.sql.gz ]]; then
				gunzip  /tmp/opensrp.sql.gz	
				PGPASSWORD=$POSTGRES_OPENSRP_PASSWORD psql -U $POSTGRES_OPENSRP_USER -h $POSTGRES_HOST -d $POSTGRES_OPENSRP_DATABASE -a -f /tmp/opensrp.sql
				echo "Do not remove!!!. This file is generated by Docker. Removing this file will reset opensrp database" > /etc/migrations/.postgres_migrations_complete 
			fi
		fi

		if [ ! -f /tmp/opensrp.sql  -a -d /tmp/opensrp-server-${OPENSRP_SERVER_TAG}/assets/tbreach_default_view_configs ]; then
			/tmp/opensrp-server-${OPENSRP_SERVER_TAG}/assets/tbreach_default_view_configs/setup_view_configs.sh -t postgres  -u $POSTGRES_OPENSRP_USER -pwd $POSTGRES_OPENSRP_PASSWORD -d $POSTGRES_OPENSRP_DATABASE -h $POSTGRES_HOST -f /tmp/opensrp-server-${OPENSRP_SERVER_TAG}/assets/tbreach_default_view_configs
			echo "Do not remove!!!. This file is generated by Docker. Removing this file will reset opensrp database" > /etc/migrations/.postgres_migrations_complete 
		elif [ ! -d /tmp/opensrp-server-${OPENSRP_SERVER_TAG}/assets/tbreach_default_view_configs ]; then
			touch  /etc/migrations/.postgres_migrations_complete
		fi
	fi

	echo "Migrations finished"
	"${psql[@]}" --username postgres <<-EOSQL
		ALTER USER $POSTGRES_OPENSRP_USER WITH NOSUPERUSER;
	EOSQL
	pg_ctl -D "$PGDATA" -m fast -w stop
	echo  'Postgres stopped'
fi
#Finished Postgres Initialization