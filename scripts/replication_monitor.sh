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
disable=/opt/ls_tools/disabled.txt
if [ "$1" = "--help" ] ; then
    echo "This is the help section of the script:"
    echo "For the first run, you need to create the sql user. To do so execute :"
    echo "sh /opt/ls_tools/replication_monitor.sh --create mysql_user mysql_password"
    echo "and replace mysql_user and mysql_password with the correct values"
    echo ""
    echo "After the user was created, in order to run the checks, execute the script with the --check option"
fi
if [ ! -d $tools ]; then mkdir $tools; fi

if [ ! -f $credentials ] ; then touch $credentials; fi

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

###Check replication
function check_replication () {
    local mysql="/usr/bin/mysql --defaults-extra-file=$credentials"

    ##### Get Slave Status #####
    mysql_status=`echo "show slave status\G" | $mysql | sed -e 's/^[[:space:]]*//g' 2>&1`

    ##### Check Replication Delay #####
    seconds_behind_master=`echo "$mysql_status" | grep "Seconds_Behind_Master" | awk '{ print $2 }'`

    ##### Check if IO thread is running #####
    io_is_running=`echo "$mysql_status" | grep "Slave_IO_Running" | awk '{ print $2 }'`

    if [ "$io_is_running" != "Yes" ]; then echo "Mysql replication broken on $server. " | /bin/mail  -s "Mysql replication broken on $server" $email; fi
}

function disable_check () {
    if [[ $(find "$disable" -mtime +1 -print) ]]; then
  echo "File $filename exists and is older than 100 days"
fi

}
if [ "$1" == "--create" ]; then  create_user; enable_mail; fi
if [ "$1" == "--check" ]; then check_replication; fi