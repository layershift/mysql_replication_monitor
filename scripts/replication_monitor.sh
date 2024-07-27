#!/bin/bash

version=2023101901

server=$(hostname)
sender=mysql-replication@${server}
tools=/opt/ls_tools
credentials=${tools}/.sqlpwd
config_file=${tools}/mysql_monitor.config
status_file=/run/$(basename $0)
debug=0

### Check if path for /opt/ls_tools and credentials file exists
if [ ! -d $tools ]; then mkdir $tools; fi
if [ ! -f $credentials ] ; then touch $credentials; fi

### Check status_file
function check_status_file () {
    if [ ! -f $status_file ] ; then 
        touch $status_file;
        echo -e "mysql_status=" >> $status_file
        echo -e "disabled_status=" >> $status_file
	echo -e "disable_timestamp=" >> $status_file
    else
        grep -v "#" $status_file | grep -q "mysql_status="
        if [ $? -ne 0 ]; then
            echo -e "mysql_status=" >> $status_file
        fi
        grep -v "#" $status_file | grep -q "disabled_status="
        if [ $? -ne 0 ]; then
            echo -e "disabled_status=" >> $status_file
	fi
	grep -v "#" $status_file | grep -q "disable_timestamp="
        if [ $? -ne 0 ]; then
            echo -e "disable_timestamp=" >> $status_file
       	fi
    fi
}

### Populate config file with mysql_status and disabled_status
function add_data () {
    if [ ! -f $config_file ] ; then 
        touch $config_file; 
        echo -e "email= ${setup_email}" >> $config_file
    else
        sed "s#email=.*#email=${setup_email}#" -i $config_file
    fi
    check_status_file
}

### Create user with credentials provided in Jps package
function create_user () {
    local password=${setup_script_mysql_password}
    local user=check_monit

    echo "DROP USER IF EXISTS 'check_monit'@'localhost';" | mysql -u${setup_user} -p${setup_password}
    echo "CREATE USER '$user'@'localhost' IDENTIFIED BY '$password';" | mysql -u${setup_user} -p${setup_password}
    echo "GRANT SUPER , REPLICATION CLIENT ON * . * TO '$user'@'localhost' IDENTIFIED BY '$password' WITH MAX_QUERIES_PER_HOUR 0 MAX_CONNECTIONS_PER_HOUR 0 MAX_UPDATES_PER_HOUR 0 MAX_USER_CONNECTIONS 0;"| mysql -u${setup_user} -p${setup_password}
    echo -e "[mysql]\nuser=$user\npassword=$password" > $credentials
    chmod 600 $credentials
}

### Enable sendmail and mailx
function enable_mail () {
    /bin/systemctl enable sendmail
    /bin/systemctl start sendmail
    /bin/yum install mailx -y 2>&1 >/dev/null
}
### Disable checks for e period; used with --disable --time=n (where n is any number of hours you want to disable the check)
function check_disable () {
    disable_check_file=/${tools}/disabled.txt
    if [ ! -f $disable_check_file ]; then touch $disable_check_file; fi
    ###last time the disabled.txt file was updated
    lastUpdate=$(date -r $disable_check_file +%s)

    ###Current time
    now=$(date +%s)

    ###disabled.txt file age in seconds/hours
    file_age_seconds=$((now - lastUpdate))
    file_age=$(((now - lastUpdate)/3600))

    ###Time variabile previously configured
    time="${time#*=}"

    ###If time is configured, add it to the config file
    disable_time=`cat $disable_check_file`
    if [ ! -z "$time" ]; then
        if [ "$disable_time" -eq "0" ]; then 
            echo "$time" > $disable_check_file ; 
        fi 
    fi
    disable_time=`cat $disable_check_file`
    if [ ${debug} -gt 0 ]; then
        echo -e "file age is $file_age and disable time is $disable_time"
    fi

    ### Check $status_file exists
    check_status_file
    ###set disable_status to true/false based on previous values
    if [ "$disable_time" -gt "$file_age" ]; then 
	sed -i 's/disabled_status=.*/disabled_status=true/g' $status_file
        sed -i "s/disable_timestamp=.*/disable_timestamp=$(date)/" $status_file
    else 
    	sed -i 's/disabled_status=.*/disabled_status=false/g' $status_file
     	echo "0" > $disable_check_file
    fi
}

### Check if mysql connection works with monitoring user
function check_mysql () {
    
    /usr/bin/mysqladmin --defaults-extra-file=$credentials ping 2>&1 >/dev/null

    ### Check $status_file exists
    check_status_file

    ###If can't connect to mysql using the credentials in the /opt/ls_tools/.sqlpwd file email support 
    if [ $? -eq 0 ]; then sed -i 's/mysql_status=.*/mysql_status=true/g' $status_file ; else sed -i 's/mysql_status=.*/mysql_status=false/g' $status_file && echo "0" > $disable_check_file  ; fi
}

### Check replication
function check_replication () {

    ### Check $status_file exists
    check_status_file

    local mysql="/usr/bin/mysql --defaults-extra-file=$credentials"

    ###Get Alert recipient
    local email=$(grep -v "^#" $config_file | grep "email="  | awk -F "=" '{ $1=""; print $0 }' | xargs)

    ###Check if monitoring is disabled
    local disabled_status=$(grep -v "^#" $status_file | grep "disabled_status=" | awk -F "=" '{print $2}')
    local disable_timestamp=$(grep -v "^#" $status_file | grep "disable_timestamp=" | awk -F "=" '{print $2}')

    if [ "${disabled_status,,}" != "false" ]; then exit 0 ; fi

    ###Check if mysql connection works
    local mysql_status=$(grep -v "^#" $status_file | grep "mysql_status=" | awk -F "=" '{print $2}')

    if [ "${mysql_status,,}" != "true" ]; then echo -e "Mysql connection broken on $server.\nmysqladmin ping failed" | if [ ${debug} -gt 0 ]; then less; else /bin/mail  -s "Mysql connection broken on $server" $email; exit 0; fi; fi   

    ###Get mysql info
    local mysql_info=`echo "show slave status\G" | $mysql | sed -e 's/^[[:space:]]*//g' 2>&1`
    ###Get replication status
    local io_is_running=`echo "$mysql_info" | grep "Slave_IO_Running:" | awk '{ print $2 }'`
    local sql_is_running=`echo "$mysql_info" | grep "Slave_SQL_Running:" | awk '{ print $2 }'`
    local seconds_behind=`echo "$mysql_info" | grep "Seconds_Behind_Master:" | awk '{ print $2 }'`

    if [[ "${io_is_running,,}" != "yes" || "${sql_is_running,,}" != "yes" || "$seconds_behind" -gt 1800 ]]; then echo -e "Mysql replication broken on $server.\n\nChecks last disabled: $disable_timestamp\n\nshow slave status\G\n$(echo "show slave status\G"|$mysql)" | if [ ${debug} -gt 0 ]; then less; else /bin/mail  -s "Mysql replication broken on $server" $email; fi; fi
}

### show slave status
function show_status () {
    local mysql="/usr/bin/mysql --defaults-extra-file=$credentials"
    echo -e "\nOn $server.\n";
    if [ $1 -eq 0 ]; then
        echo "show slave status\G"|$mysql
    else
        echo "show slave status\G"|$mysql | egrep "Running:|Seconds_Behind_Master"
    fi
    exit 0;
}

### Uninstall
function uninstall () {
    /usr/bin/mysql -u${setup_user} -p${setup_password} -e "DROP USER IF EXISTS 'check_monit'@'localhost';"
    /usr/bin/rm -f $credentials
    /usr/bin/rm -f $config_file
    /usr/bin/rm -f $status_file
    /usr/bin/rm -f $disable_check_file
}

while [[ $# -gt 0 ]]; do
    param="$1"
    shift
    case $param in
        --help)
            cat <<EOF
This script is designed to monitor and email the configured "Alert recipient(s)" if the database replication fails

Before the replication can be monitored we need to set up a monitoring database user using --create

Version: $version

    sh $0 --create 'mysql_user' 'mysql_password' 'recipient_email' 'script_mysql_password'

    sh $0 --check                                       Check the slave status and email if any issues
    sh $0 --debug --check                               Check the slave status and print any issues

    sh $0 --disable --time=n                            Suppress the checks for n hours
    sh $0 --status                                      Show slave status
    sh $0 --status --short                              Show Running:|Seconds_Behind_Master from slave status

    sh $0 --uninstall 'mysql_user' 'mysql_password'     Remove monitoring database user and related fils

EOF
            exit 0;
        ;;
        --debug)
            debug=1
        ;;
        --create)
            setup_user=${1}
            shift
            setup_password=${1}
            shift
            setup_email=${1:-root@localhost}
            shift
            if [[ ${setup_user} == 'mysql_user' && ${setup_password} == 'mysql_password' && ${setup_email} == 'recipient_email' ]]; then
                echo "Error: Please enter actual database connection details"
                exit 1;
            fi
            randomPassword=$(openssl rand -base64 12 )
            setup_script_mysql_password=${1:-$randomPassword}
            shift

            create_user;
            enable_mail;
            add_data;
        ;;
        --disable)
            time=0
            if [ ! -z $1 ]; then
                case $1 in
                    --time=*)
                        time=${1#*=};
                    ;;
                    --time)
                        time=${2}
                        shift
                    ;;
                esac
                shift
            fi
            check_disable
        ;;
        --check)
            check_disable;
            check_mysql;
            check_replication;
        ;;
        --status)
            short=0
            if [ ! -z $1 ]; then
                 case $1 in
                    --short)
                        short=1
                    ;;
                 esac
                 shift
            fi

            show_status $short;
        ;;
        --uninstall)
            setup_user=${1}
            shift
            setup_password=${1}
            shift

            uninstall;
        ;;
    esac
done;
