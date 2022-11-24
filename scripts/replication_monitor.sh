#!/bin/bash
password=$(openssl rand -base64 12 )
user=check_monit
setup_password=${3}
setup_user=${2}
setup_email=${4:-root@localhost}
sender=mysql-replication@$(hostname)
credentials=/opt/ls_tools/.sqlpwd
tools=/opt/ls_tools
server=$(hostname)
time=${2}
config_file=/opt/ls_tools/mysql_monitor.config
status_file=/run/$(basename $0)

if [ "$1" == "--help" ] ; then
    echo "This is the help section of the script:"
    echo "For the first run, you need to create the sql user. To do so execute :"
    echo "sh /opt/ls_tools/replication_monitor.sh --create mysql_user mysql_password"
    echo "and replace mysql_user and mysql_password with the correct values"
    echo ""
    echo "After the user was created, in order to run the checks, execute the script with the --check option"
    echo "If you want to disable the check for a period, you can use --disable --time=n (where n is any time in hours you want it disabled)"
    exit 0;
fi
### Check if path for /opt/ls_tools and credentials  file exists
if [ ! -d $tools ]; then mkdir $tools; fi

if [ ! -f $credentials ] ; then touch $credentials; fi

###Populate config file with mysql_status and disabled_status
function add_data () {
    if [ ! -f $config_file ] ; then 
        touch $config_file; 
        echo -e "email= ${setup_email}" >> $config_file
    else
        sed "s#email=.*#email=${setup_email}#" -i $config_file
    fi
    if [ ! -f $status_file ] ; then touch $status_file; fi
    echo -e "mysql_status= " >> $status_file
    echo -e "disabled_status= " >> $status_file
}
###Create user with credentials provided in Jps package
function create_user () {
    echo "CREATE USER '$user'@'localhost' IDENTIFIED BY '$password';" | mysql -u${setup_user} -p${setup_password}
    echo "GRANT SUPER , REPLICATION CLIENT ON * . * TO '$user'@'localhost' IDENTIFIED BY '$password' WITH MAX_QUERIES_PER_HOUR 0 MAX_CONNECTIONS_PER_HOUR 0 MAX_UPDATES_PER_HOUR 0 MAX_USER_CONNECTIONS 0;"| mysql -u${setup_user} -p${setup_password}
    echo -e "[mysql]\nuser=$user\npassword=$password" > $credentials
    chmod 600 $credentials
}

###Enable sendmail and mailx
function enable_mail () {
    /bin/systemctl enable sendmail
    /bin/systemctl start sendmail
    /bin/yum install mailx -y 2>&1 >/dev/null
}
###Disable checks for e period; used with --disable --time=n (where n is any number of hours you want to disable the check)
function check_disable () {
    disable_check_file=/opt/ls_tools/disabled.txt
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
            if [ "$disable_time" -eq "0" ]; then echo "$time" > $disable_check_file ; fi 
        fi
    disable_time=`cat $disable_check_file`
    echo -e "file age is $file_age and disable time is $disable_time"
    ###set disable_status to true/false based on previous values
    if [ "$disable_time" -gt "$file_age" ]; then sed -i 's/disabled_status=.*/disabled_status= true/g' $status_file ; else sed -i 's/disabled_status=.*/disabled_status= false/g' $status_file && echo "0" > $disable_check_file  ; fi
}

###Check if mysql connection works with monitoring user
function check_mysql () {
    
    /usr/bin/mysqladmin --defaults-extra-file=$credentials ping 2>&1 >/dev/null
    ###If can't connect to mysql using the credentials in the /opt/ls_tools/.sqlpwd file email support 
    if [ $? -eq 0 ]; then sed -i 's/mysql_status=.*/mysql_status= true/g' $status_file ; else sed -i 's/mysql_status=.*/mysql_status= false/g' $status_file && echo "0" > $disable_check_file  ; fi
}

###Check replication
function check_replication () {


    local mysql="/usr/bin/mysql --defaults-extra-file=$credentials"

    ###Get Alert recipient
    local email=$(grep -v "^#" $config_file | grep "email="  | awk -F "=" '{ $1=""; print $0 }' | xargs)

    ###Check if monitoring is disabled
    local disabled_status=$(grep -v "^#" $status_file | grep "disabled_status=" $status_file | awk -F "=" '{ $1=""; print $0 }' | xargs)

    if [ "$disabled_status" != "false" ]; then exit 0 ; fi

    ###Check if mysql connection works
    local mysql_status=$(grep -v "^#" $status_file | grep "mysql_status=" | awk -F "=" '{ $1=""; print $0 }' | xargs)

    if [ "$mysql_status" != "true" ]; then echo -e "Mysql connection broken on $server.\nmysqladmin ping failed" | /bin/mail  -s "Mysql connection broken on $server" $email; exit 0; fi   

    ###Get mysql info
    local mysql_info=`echo "show slave status\G" | $mysql | sed -e 's/^[[:space:]]*//g' 2>&1`
    ###Get replication status
    local io_is_running=`echo "$mysql_info" | grep "Slave_IO_Running" | awk '{ print $2 }'`

    if [ "$io_is_running" != "Yes" ]; then echo -e "Mysql replication broken on $server.\n$(echo "show slave status\G"|$mysql)" | /bin/mail  -s "Mysql replication broken on $server" $email; fi
}

###Uninstall
function uninstall () {
    /usr/bin/mysql -u${setup_user} -p${setup_password} -e "DROP USER 'check_monit'@'localhost';"
    /usr/bin/rm -f $credentials
    /usr/bin/rm -f $config_file
    /usr/bin/rm -f $status_file
    /usr/bin/rm -f $disable_check_file

}

if [ "$1" == "--create" ]; then  create_user; enable_mail; add_data; fi
if [ "$1" == "--disable" ]; then check_disable ; fi
if [ "$1" == "--check" ]; then check_disable; check_mysql; check_replication; fi
if [ "$1" == "--uninstall" ]; then uninstall; fi
