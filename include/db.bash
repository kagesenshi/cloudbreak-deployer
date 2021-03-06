db-init() {
    env-import DB_DUMP_VOLUME cbreak_dump
    env-import REMOVE_CONTAINER "--rm"
    cloudbreak-conf-tags
    cloudbreak-conf-db
}

db-getpostgres-image-version() {
    declare desc="Detects which docker image version is matching the db volume"
    declare dbVolume=${1:? required: dbVolume}

    local pgver=$(docker run --rm \
        -v $dbVolume:/data \
        alpine:$DOCKER_TAG_ALPINE cat /data/PG_VERSION
    )
    echo "${pgver}-alpine"

}

db-set-dump() {
    declare desc="sets an sql dump as latest"
    declare dbName=${1:? required: dbName}
    declare name=${2:? required: name}

    local volDir="/dump"
    local dumpDir="$volDir/$dbName/${name}"
    local latestDir="$volDir/$dbName/latest"

    docker run --rm \
        -v $DB_DUMP_VOLUME:$volDir \
        alpine:$DOCKER_TAG_ALPINE \
        ls $dumpDir \
            | debug-cat

    debug "create latest simlink $latestDir -> $dumpDir"
    docker run --rm \
        -v $DB_DUMP_VOLUME:$volDir \
        alpine:$DOCKER_TAG_ALPINE \
        sh -xc "rm -f $latestDir && ln -s $dumpDir $latestDir" 2>&1 \
            | debug-cat
}

db-dump() {
    declare desc="creates an sql dump from the db volume"
    declare dbVolume=${1:? required: dbVolume}
    declare dbName=${2:-postgres}
    declare name=${3}

    if ! ( [[ $dbVolume =~ ^/ ]] || docker volume inspect $dbVolume &>/dev/null ); then
        error "docker volume $dbVolume doesnt exists"
        _exit 1
    fi

    if docker run --rm -v $dbVolume:/data alpine:$DOCKER_TAG_ALPINE test -f /data/PG_VERSION &> /dev/null; then
        debug "postgres DB exists on volume: $dbVolume"
    else
        error "$dbVolume doesnt contains a postgres DB"
        _exit 1
    fi

    local volDir="/dump"
    local contName=cbreak_dump
    docker rm -f $contName &>/dev/null || :

    docker run -d \
        --name $contName \
        -v $dbVolume:/var/lib/postgresql/data \
        -v $DB_DUMP_VOLUME:$volDir \
        postgres:$(db-getpostgres-image-version $dbVolume) | debug-cat

    local timeStamp=$(date "+%Y%m%d_%H%M")
    if [[ "$dbName" == "postgres" ]] ; then
        volDir+="/${dbVolume##*/}"
    else
        volDir+="/${dbName}"
    fi

    local dumpDir="$volDir/${timeStamp}"
    local latestDir="$volDir/latest"
    
    debug "create dump dir: $dumpDir"
    docker exec $contName sh -c "mkdir -p $dumpDir"

    db-wait-for-db-cont $contName

    docker exec $contName sh -c 'pg_dump -U postgres '$dbName' > '$dumpDir'/dump.sql' | debug-cat

    debug "create latest simlink $latestDir -> $dumpDir"
    docker exec $contName sh -xc "rm -f $latestDir && ln -s $dumpDir $latestDir" 2>&1 | debug-cat

    if [[ "$name" ]]; then
        local nameDir="$volDir/$name"
        debug "create named simlink $nameDir -> $dumpDir"
        docker exec $contName sh -xc "rm -f $nameDir && ln -s $dumpDir $nameDir" 2>&1 | debug-cat
    fi

    db-stop-database $contName
}

db-initialize-databases() {
    declare desc="Initialize and migrate databases"

    cloudbreak-config
    
    if docker volume inspect $COMMON_DB_VOL &>/dev/null; then
        debug "no db initialization and migration is needed"
        return
    fi
    
    info $desc
    for db in cbdb uaadb periscopedb; do
        if docker run --rm -v $CB_DB_ROOT_PATH/$db:/data alpine:$DOCKER_TAG_ALPINE test -f /data/PG_VERSION &> /dev/null; then
            db-dump $CB_DB_ROOT_PATH/$db
            db-restore-volume-from-dump $COMMON_DB_VOL $db
        else
            debug "no data to migrate from $CB_DB_ROOT_PATH/$db"
            local contName=cbreak_create
            db-start-database $contName $COMMON_DB_VOL
            db-create-database $contName $db
            db-stop-database $contName
        fi
    done
}

db-wait-for-db-cont() {
    declare desc="wait for db container readiness"
    declare contName=${1:? required db container name}

    local maxtry=${RETRY:=30}
    while (! docker run $REMOVE_CONTAINER --net=container:$contName --entrypoint=pg_isready postgres:$DOCKER_TAG_POSTGRES -h 127.0.0.1 &> /dev/null) && (( maxtry -= 1 > 0 )); do
        debug "waiting for DB: $contName to start [tries left: $maxtry] ..."
        sleep 1;
    done
}

db-start-database() {
    declare desc="Start a postgresql database and wait for readyness"
    declare contName=${1:? required: contName}
    declare volName=${2:? required: volName}
    local dbCreatedFile="/var/lib/postgresql/data/.created"

    docker rm -f $contName &>/dev/null || :
    docker run -d \
        --name $contName \
        -v $volName:/var/lib/postgresql/data \
        -v $DB_DUMP_VOLUME:/dump \
        postgres:$DOCKER_TAG_POSTGRES \
        bash -c "echo 'touch $dbCreatedFile' > /docker-entrypoint-initdb.d/created.sh && /docker-entrypoint.sh postgres" \
            | debug-cat

    local maxtry=${RETRY:=30}
    while (! docker run $REMOVE_CONTAINER --volumes-from $contName --entrypoint=test postgres:$DOCKER_TAG_POSTGRES -e $dbCreatedFile &> /dev/null ) && (( maxtry -= 1 > 0 )); do
        debug "waiting for DB [tries left: $maxtry] ..."
        sleep 1;
    done

    db-wait-for-db-cont $contName
}

db-stop-database() {
    declare desc="Stop a postgresql database if needed"
    declare contName=${1:? required: contName}

    docker stop -t ${DOCKER_STOP_TIMEOUT} $contName | debug-cat
    if [[ "$REMOVE_CONTAINER" ]]; then
        docker rm -f $contName | debug-cat
    fi
}

db-create-database() {
    declare desc="Creates new empty database"
    declare contName=${1:? required: contName}
    declare newDbName=${2:? required: newDbName}

    if [[ $newDbName != "postgres" ]]; then
        debug "create new database: $newDbName"
        docker run $REMOVE_CONTAINER --net=container:$contName --entrypoint=psql postgres:$DOCKER_TAG_POSTGRES -h 127.0.0.1 -U postgres -c "create database $newDbName" | debug-cat
    fi
}

db-restore-volume-from-dump() {
    declare desc="initialize the DB if needed, from a previous dump"
    declare volName=${1:? required: new volName}
    declare dumpDbName=${2:? required dumpDbName cbdb/pcdb/uaadb}
    declare newDbName=${3:-$dumpDbName}

    debug "db: $newDbName in volume: $volName will be restore from: $dumpDbName dump"
    local dbDoneFile="/var/lib/postgresql/data/.${newDbName}.done"
    
    local contName=cbreak_initdb
    docker rm -f $contName &>/dev/null || :
    debug "test if $dbDoneFile exists ..."
    if docker run --rm -v $volName:/var/lib/postgresql/data/ alpine:$DOCKER_TAG_ALPINE test -e $dbDoneFile &>/dev/null; then
        info "db initaliazation is already DONE"
    else
        debug "creates volume: $volName"
        local contName=cbreak_restore

        db-start-database $contName $volName
        db-create-database $contName $newDbName

        docker exec $contName psql -U postgres $newDbName -f /dump/$dumpDbName/latest/dump.sql > restore_vol_$volName.log
        docker exec $contName touch $dbDoneFile | debug-cat

        db-stop-database $contName
    fi
}

db-list-dumps() {
    declare desc="creates an sql dump from the db volume"
    docker run $REMOVE_CONTAINER \
        -v $DB_DUMP_VOLUME:/dump \
        alpine:$DOCKER_TAG_ALPINE \
          find /dump -follow -name \*.sql -exec ls -lh {} \; | tr ' ' '~' | cut -d'~' -f 22,18
}

