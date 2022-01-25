#!/bin/bash
password=$(openssl rand -base64 12 )
user=check_monit
default_password=$3
default_user=$2
sender=mysql-replication@$(hostname)
email=monitor@layershift.com
credentials=/opt/ls_tools/.sqlpwd
tools=/opt/ls_tools
server=$(hostname)
time=$2
config_file=/opt/ls_tools/mysql_monitor.config

if [ "$1" = "--help" ] ; then
    echo "This is the help section of the script:"
    echo "For the first run, you need to create the sql user. To do so execute :"
    echo "sh /opt/ls_tools/replication_monitor.sh --create mysql_user mysql_password"
    echo "and replace mysql_user and mysql_password with the correct values"
    echo ""
    echo "After the user was created, in order to run the checks, execute the script with the --check option"
    echo "If you want to disable the check for a period, you can use --check --time=n (where n is any time in hours you want it disabled)"
fi
if [ ! -d $tools ]; then mkdir $tools; fi

if [ ! -f $credentials ] ; then touch $credentials; fi

###Populate config file
function add_data () {
    if [ ! -f $config_file ] ; then touch $config_file; fi
    echo "mysql_status= " > $config_file
    echo "disabled_status= " > $config_file
}
###Create user
function create_user () {
    echo "CREATE USER '$user'@'localhost' IDENTIFIED BY '$password';" | mysql -u$default_user -p$default_password
    echo "GRANT SUPER , REPLICATION CLIENT ON * . * TO '$user'@'localhost' IDENTIFIED BY '$password' WITH MAX_QUERIES_PER_HOUR 0 MAX_CONNECTIONS_PER_HOUR 0 MAX_UPDATES_PER_HOUR 0 MAX_USER_CONNECTIONS 0;"| mysql -u$default_user -p$default_password
    echo -e "[mysql] \n user=$user \n password=$password" > $credentials
    chmod 600 $credentials
}

###Enable sendmail and mailx
function enable_mail () {
    /bin/systemctl enable sendmail
    /bin/systemctl start sendmail
    /bin/yum install mailx -y
}
###Disable checks for e period
function check_disable () {
    disable_check_file=/opt/ls_tools/disabled.txt
    lastUpdate=$(date -r $disable_check_file +%s)
    now=$(date +%s)
    file_age_seconds=$((now - lastUpdate))
    file_age=$(((now - lastUpdate)/3600))
    time="${time#*=}"
    disable_time=`cat $disable_check_file`
    if [ ! -f $disable_check_file ]; then touch $disable_check_file; fi
    if [ "$disable_time" -eq "0" ]; then echo "$time" > $disable_check_file ; fi
    disable_time=`cat $disable_check_file`
    echo -e "file age is $file_age and the settings are $disable_time"
    if [ "$disable_time" -gt "$file_age" ]; then sed -i 's/disabled_status=/disabled_status= true/g' $config_file ; else sed -i 's/disabled_status=/disabled_status= false/g' $config_file && echo "0" > $disable_check_file  ; fi
}

###Check if mysql connection works with monitoring user
function check_mysql () {
    local mysql="/usr/bin/mysql --defaults-extra-file=$credentials"
    echo "show databases;" | $mysql
    if [ "$?" == "0" ]; then 's/mysql_status=/mysql_status= true/g' $config_file ; else 's/mysql_status=/mysql_status= false/g' $config_file ; fi
}

###Check replication
function check_replication () {
    local mysql="/usr/bin/mysql --defaults-extra-file=$credentials"
    local disabled_status=`grep "disabled_status=" $config_file  |awk '{ print $2 }'`
    local mysql_status=`grep "mysql_status=" $config_file  |awk '{ print $2 }'`
    local io_is_running=`echo "$mysql_status" | grep "Slave_IO_Running" | awk '{ print $2 }'`
    ##### Check if IO thread is running #####
    if [ "$disabled_status" != "false" ]; then exit 0 ; fi
    if [ "$mysql_status" != "true" ]; then echo "Mysql connection broken on $server. " | /bin/mail  -s "Mysql connection broken on $server" $email; exit 0; fi   
    if [ "$io_is_running" != "Yes" ]; then echo "Mysql replication broken on $server. " | /bin/mail  -s "Mysql replication broken on $server" $email; fi
}

###Uninstall
function uninstall () {
    /usr/bin/mysql -u$default_user -p$default_password -e "DROP USER 'check_monit'@'localhost';"
    /usr/bin/rm -f $credentials
    /usr/bin/rm -f $config_file
    /usr/bin/rm -f $disable_check_file

}

if [ "$1" == "--create" ]; then  create_user; enable_mail; add_data; fi
if [ "$1" == "--disable" ]; then check_disable ; fi
if [ "$1" == "--check" ]; then check_disable; check mysql; check_replication; fi
if [ "$1" == "--uninstall" ]; then uninstall; fi
