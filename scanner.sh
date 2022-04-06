#!/bin/bash

randomID="abc"
keyName="Appsec-Scanner-Key-Pair-$randomID"
keyLocation="/tmp/$keyName.pem"
vpcName="Appsec-Scanner-VPC-$randomID"
subnetName="Appsec-Scanner-Pub-Subnet-$randomID"
internetGWName="Appsec-Scanner-InternetGW-$randomID"
routeTableName="Appsec-Scanner-RouteTable-$randomID"
securityGroupName="Appsec-Scanner-SecurityGroup-$randomID"
scannerInstanceName="Appsec-Scanner-Ec2-Instance-$randomID"
snapshotName="Appsec-Scanner-Ec2-Snapshot-$randomID"
clonedVolumeName="Appsec-Scanner-Cloned-Volume-$randomID"
terminatedState="terminated"
completedState="completed"
attachedState="attached"
runningState="running"
regionName="ap-south-1"
username="ec2-user"
profileName="maerifat"
profile="--profile $profileName"
region="--region ${regionName}"
scanCmd="scan"
forceCleanCmd="forceclean"


getReglionList () {
    regionList=($(aws ec2 describe-regions $profile   --output text --query 'Regions[].RegionName[]'))
    totalRegions=${#regionList[@]}
}


getReglionList

getExistingVPCs () {

    for regionName in ${regionList[*]}; do 
    aws ec2 describe-vpcs $profile $region   --output text --query 'Vpcs[].VpcId'
    done
}

getExistingVPCIps () {
    VPCS=$(aws ec2 describe-vpcs $profile $region   --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' --output text |cut -d "/" -f1|sort -u)
    VPCSarray=("$VPCS")
}

#generate all new possible cidr for availibility
findCidr () {
    for serial in {254..1};do
        CIDR="10.$serial.0.0"
        
        #Check if newcidr exists or not
        if  ! [[  "${VPCSarray[*]}"  =~   ${CIDR}  ]]; then
            availableVPCCIDR=$CIDR
            echo "New available CIDR $availableVPCCIDR/16 found."
            break
        fi
    done
}

#generate key-pair
generateKey () {
    aws ec2 create-key-pair --key-name $keyName  --query 'KeyMaterial' --output text $profile $region    > /tmp/$keyName.pem
    echo "New SSH key has been created and saved as /tmp/$keyName.pem"
}






findMyIp (){
    myIp=$(curl -s ifconfig.me)
    echo "You public IP address is $myIp"
}


createVPC () {
    newVPCId=$(aws ec2 create-vpc --cidr-block "${availableVPCCIDR}/16" --query 'Vpc.VpcId' --output text $profile $region )
    echo "New VPC $newVPCId  has been created."
    
    #adding tag
    aws ec2 create-tags --resources "${newVPCId}" --tags "Key=Name,Value=$vpcName" $profile $region 
    echo "Tagged $newVPCId with Name as $vpcName"
    
    #enabling dns hostnames
    aws ec2 modify-vpc-attribute --vpc-id "$newVPCId" --enable-dns-hostnames "{\"Value\":true}" $profile $region 
    echo "Enabled dns host names for $newVPCId ($vpcName)"
    
}


getRouteTable () {
    routeTableId=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$newVPCId --output text $profile $region \
    --query 'RouteTables[].Associations[?Main==`true`][].RouteTableId')

    echo "Route Table of $newVPCId is $routeTableId"
        #Adding tag
    aws ec2 create-tags --resources $routeTableId --tags "Key=Name,Value=$routeTableName" $profile $region 
    echo "Tagged $routeTableId with Name as $routeTableName"
}


createSubnet () {
    subnetCIDR=$(echo "$availableVPCCIDR"| awk -F "." '{$3=1; print $1 "." $2 "." $3 "." $4}')
    pubSubnetId=$(aws ec2 create-subnet --vpc-id $newVPCId --cidr-block $subnetCIDR/24 \
    --availability-zone ap-south-1a --query 'Subnet.SubnetId' --output text $profile $region )
    echo "New subnet $subnetCIDR/24 ($pubSubnetId) has been created."
    
    #adding tag
    aws ec2 create-tags --resources $pubSubnetId --tags "Key=Name,Value=$subnetName" $profile $region 
    echo "Tagged $pubSubnetId with Name as $subnetName"
    
    #enabling auto assign public Ip
    aws ec2 modify-subnet-attribute --subnet-id $pubSubnetId --map-public-ip-on-launch $profile $region 
    echo "Enabled auto assignment of public Ip to $pubSubnetId ($subnetName)"
}


createInternetGW () {
    internetGWId=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text $profile $region )
    echo "Internet Gateway $internetGWId created."
    
    aws ec2 create-tags --resources $internetGWId --tags "Key=Name,Value=$internetGWName" $profile $region 
    echo "Tagged $internetGWId with Name as $internetGWName"
    
}



attachInternetGW () {
    aws ec2 attach-internet-gateway --vpc-id $newVPCId --internet-gateway-id $internetGWId $profile $region 
    echo "Attached Internet Gateway $internetGWId to VPC $newVPCId"
    
}


# createRouteTable () {
#     routeTableId=$(aws ec2 create-route-table --vpc-id $newVPCId  --query 'RouteTable.RouteTableId' --output text $profile $region )
#     echo "New route table $routeTableId has been created."
    
#     #Adding tag
#     aws ec2 create-tags --resources $routeTableId --tags "Key=Name,Value=$routeTableName" $profile $region 
#     echo "Tagged $routeTableId with Name as $routeTableName"
# }


createRouteToInternetGW () {
    ## Create route to Internet Gateway
    aws ec2 create-route \
    --route-table-id $routeTableId \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $internetGWId $profile $region  > /dev/null
    echo "Created route for $routeTableId ($routeTableName) to $internetGWId ($internetGWName)."
}

associatePubSubnetWithRouteTable (){
    ## Associate the public subnet with route table
    routeTableAssociationId=$(aws ec2 associate-route-table  \
    --subnet-id $pubSubnetId \
    --route-table-id $routeTableId \
    --query 'AssociationId'\
    --output text $profile $region )
    echo "Associated ($routeTableAssociationId) route table $routeTableId with the subnet $pubSubnetId."
}


createSecurityGroup () {
    
    ## Create a security group
    securityGroupId=$(aws ec2 create-security-group \
    --vpc-id $newVPCId \
    --group-name $securityGroupName \
    --description 'Appsec-Scanner VPC - non default security group' $profile $region )
    echo "New security group $securityGroupId ($securityGroupName) as been created."
    
    
    ##Getting security group id
    # securityGroupId=$(aws ec2 describe-security-groups $profile $region  \
    # --filters "Name=vpc-id,Values=$newVPCId" \
    # --output json|  jq '.SecurityGroups'|jq '.[] | select(.GroupName == "'$securityGroupName'")'|jq '.GroupId'| tr -d '"') 
    
    # echo "Created security group"
    
    ##Tagging security group
    aws ec2 create-tags \
    --resources $securityGroupId \
    --tags "Key=Name,Value=$securityGroupName" $profile $region 
    echo "Tagged $securityGroupId with Name as $securityGroupName"
    
    
}


createIngressRules () {
    ## Create security group ingress rules
    aws ec2 authorize-security-group-ingress \
    --group-id $securityGroupId \
    --protocol tcp --port 22 --cidr "$myIp/32"  $profile $region  > /dev/null 
    echo "Allowing SSH from $myIp on port 22 for $securityGroupId ($securityGroupName)."
}

##BUILDING END
####
####




runInstance () {

    scannerInstanceId=$(aws ec2 run-instances $profile $region \
    --image-id ami-04893cdb768d0f9ee \
   --instance-type t2.micro \
    --subnet-id $pubSubnetId \
    --security-group-ids $securityGroupId \
    --associate-public-ip-address \
    --key-name $keyName \
    --output text --query 'Instances[0].InstanceId')

    echo "Ec2 Instance $scannerInstanceId has been started."

    aws ec2 create-tags --resources $scannerInstanceId --tags "Key=Name,Value=$scannerInstanceName" $profile $region  > /dev/null
}


##BUILDING INFRASTRUCTURE
####
####






#for tempRegion in  ${regionList[*]};do  \

getVolumes () {
volumeIdsArray=($(aws ec2 describe-volumes $profile $region   \
--output text --query 'Volumes[].VolumeId' --output text))

echo "Collected Volumes on region $regionName"
echo ${volumeIdsArray[*]}
totalVolumes=${#volumeIdsArray[@]}
((lastVolumeNumber=$totalVolumes-1))
}





createSnapshot () {

    for volumeNumber in $(seq 0 $lastVolumeNumber ) ;do 

        snapshotId=$(aws ec2 create-snapshot $profile $region  --volume-id ${volumeIdsArray[$volumeNumber]}  \
        --description "This snapshot has been created by appsec scanner." --query 'SnapshotId' --output text)
        echo "Created snapshot $snapshotId of volume ${volumeIdsArray[$volumeNumber]} "
        
        snapShotsIdArray+=($snapshotId)

        aws ec2 create-tags --resources $snapshotId --tags "Key=Name,Value=$snapshotName" $profile $region  > /dev/null
        echo "Tagged $snapshotId with Name as $snapshotName"
        echo ""
   done

}



createAllRegionsSnapShots () {

    for regionName in ${regionList[*]};do
        region="--region $regionName"
        echo "we are searching $regionName"
        getVolumes

        if ! [ -z "${volumeIdsArray[*]}" ];then 
            createSnapshot

            for snapshotId in ${snapShotsIdArray[*]};do
                waitForSnapshotCompletion
                createVolume

                for $clonedVolumeId in ${clonedVolumeIdsArray[*]};do
                    waitForRunningScannerInstance
                    attachVolume
                    waitForClonedVolumeAttachment
                    
                    scan #to create
                    detachVolume #to create
                    waitForClonedVolumeDetachment # to create
                    deleteVolume


                done

                deleteSnapshot
            done


        fi

    echo "These are snapshotid ${snapShotsIdArray[*]}"
    done

}


getSnapshots () {
    echo ""
}







getSnapshotState () {
    snapshotState=$(aws ec2 describe-snapshots --snapshot-id $snapshotId  $profile $region  --output text \
    --query 'Snapshots[].State')

}

waitForSnapshotCompletion () {
    if [[ "$snapshotState" != "$completedState" ]];then 
        echo "Snapshot $snapshotId in still in $snapshotState state. Please wait while snapshot is created."
        sleep 20
        getSnapshotState
        waitForSnapshotCompletion 
    else
        echo "Snapshot $snapshotId ($snapshotName) has now been created."
    fi

}




createVolume () {
    clonedVolumeId=$(aws ec2 create-volume $profile $region  \
    --volume-type io1 \
    --iops 1000 \
    --snapshot-id $snapshotId \
    --availability-zone ap-south-1a --output text --query 'VolumeId')

    echo "Created new volume $clonedVolumeId from $snapshotId"

    clonedVolumeIdsArray+=($clonedVolumeId)

    aws ec2 create-tags --resources $clonedVolumeId --tags "Key=Name,Value=$clonedVolumeName" $profile $region  > /dev/null
    echo "Tagged $clonedVolumeId with Name as $clonedVolumeName"
    
}




waitForRunningScannerInstance () {
    if [[ "$instanceState" != "$runningState" ]];then 


        echo "Instance $scannerInstanceId in still in $instanceState state. Please wait while the instance starts running."
        sleep 5
        getInstanceState
        waitForRunningScannerInstance 
    else
        echo "Instance $scannerInstanceId is now in running state."
    fi

}





attachVolume (){
    aws ec2 attach-volume $profile $region \
    --device /dev/sdfabc \
    --instance-id $scannerInstanceId \
    --volume-id $clonedVolumeId

    
    echo "Initiated attachment of $clonedVolumeId with $scannerInstanceId"
}


getClonedVolumeState () {
    clonedVolumeState=$(aws ec2 describe-volumes --volume-id $clonedVolumeId $profile $region  \
     --output text  --query 'Volumes[].Attachments[].State')

}


waitForClonedVolumeAttachment () {
    if [[ "$clonedVolumeState" != "$attachedState" ]];then 
        echo "Cloned Volume $clonedVolumeId in still in $clonedVolumeState state. Please wait while volume is attached to instance"
        sleep 5
        getClonedVolumeState
        waitForClonedVolumeAttachment
    else
        echo "Volume $clonedVolumeId ($clonedVolumeName) has now been attached to $scannerInstanceId."
    fi

}



fetchInstanceIp (){
    instanceIpAddress=$(aws ec2 describe-instances --instance-id  $scannerInstanceId $profile $region \
    --output text  --query 'Reservations[].Instances[].PublicIpAddress')
    echo "Public Ip address of $scannerInstanceId is $instanceIpAddress"
}


sshInstance () {

    echo "Initiated ssh connection"
    chmod 600 $keyLocation

    echo "Try manual connection: ssh -i $keyLocation -o StrictHostKeyChecking=no $username@$instanceIpAddress"

    sshCommands="lsblk;pwd;whoami;df -h"

    ssh -i $keyLocation -o StrictHostKeyChecking=no $username@$instanceIpAddress "$sshCommands"

}





deleteSnapshot () {
    aws ec2 delete-snapshot $profile $region  --snapshot-id $snapshotId 
    echo "Delete snapshot $snapshotId ($snapshotName)"
}


deleteVolume () {
    aws ec2 delete-volume --volume-id $clonedVolumeId $profile $region  > /dev/null
    echo "Deleted new volume $clonedVolumeId ($clonedVolumeName)"
}


##CLEANSING START
####
####

terminateInstance () {
    aws ec2 terminate-instances --instance-ids $scannerInstanceId $profile $region  > /dev/null
    echo "Initiated termination of Ec2 instance $scannerInstanceId ($scannerInstanceName)."
}



getInstanceState () {
    instanceState=$(aws ec2 describe-instances --instance-id $scannerInstanceId  $profile $region \
    --output text --query 'Reservations[].Instances[].State.Name')

}

waitForInstanceTermination () {
    if [[ "$instanceState" != "$terminatedState" ]];then 
        echo "Ec2 Instance $scannerInstanceId in still in $instanceState state. Please wait while Ec2 instance is terminated."
        sleep 15
        getInstanceState
        waitForInstanceTermination 
    else
        echo "Ec2 Instance $scannerInstanceId ($scannerInstanceName) has now been terminated."
    fi

}


deleteSecurityGroup () {
    ## Delete custom security group
    aws ec2 delete-security-group --group-id $securityGroupId $profile $region 
    echo "Deleted security group $securityGroupId ($securityGroupName)"
}


detachInternetGW (){
    aws ec2 detach-internet-gateway --internet-gateway-id $internetGWId  --vpc-id $newVPCId $profile $region 
    echo "Detached Internet Gateway $internetGWId from VPC $newVPCId"
}


deleteInternetGW () {
    aws ec2 delete-internet-gateway --internet-gateway-id $internetGWId $profile $region 
    echo "Deleted Internet Gateway $internetGWId ($internetGWName)"
}



disassociatePubSubnetFromRouteTable () {
    aws ec2 disassociate-route-table --association-id $routeTableAssociationId $profile $region 
    echo "Disassociated route table ($routeTableId) from the subnet ($pubSubnetId)."
}



# deleteRouteTable () {
#     aws ec2 delete-route-table --route-table-id $routeTableId $profile $region 
#     echo "Deleted route table $routeTableId ($routeTableName)"
# }


deleteSubnet () {
    aws ec2 delete-subnet --subnet-id "$pubSubnetId" $profile $region 
    echo "Subnet $subnetCIDR/24 ($pubSubnetId) has been deleted."
}

deleteKey () {
    aws ec2 delete-key-pair --key-name $keyName $profile $region  --output json
    rm -f /tmp/$keyName.pem
    echo "SSH key has been deleted and /tmp/$keyName.pem has been removed."
}

deleteVPC () {
    aws ec2 delete-vpc --vpc-id "$newVPCId" $profile $region 
    echo "VPC $newVPCId ($vpcName) has been deleted."
    echo "Scan Completed, Your system is infected."|espeak -p 50 -s 130
    echo ""
}





#Force Clean

getBadInstances () {
    
    badInstancesArray=($(aws ec2 describe-instances $profile $region  --output text --filters Name=tag:Name,Values=$scannerInstanceName \
    --query 'Reservations[].Instances[].InstanceId'))

    if ! [ -z "${badInstancesArray[*]}" ];then 
        echo "The backlog instances will be deleted: " "${badInstancesArray[*]}"
    fi


}



terminateBadInstances () {

    if ! [ -z "${badInstancesArray[*]}" ];then 

        for badInstance in ${badInstancesArray[*]};do

            aws ec2 terminate-instances --instance-ids $badInstance $profile $region  
            echo "Initiated termination of backlog instances"
        done

    else
        echo "There are no backlog instances to terminate. "
    fi

}



getBadInstancesStates () {

    if ! [ -z "${badInstancesArray[*]}" ];then 

        badInstancesState=$(aws ec2 describe-instances $profile $region  --output text --filters Name=tag:Name,Values=$scannerInstanceName \
        --query 'Reservations[].Instances[].State.Name'|xargs| tr " " "\n"|sort -u)
    fi
}




waitForBadInstancesTermination () {
    if ! [ -z "${badInstancesArray[*]}" ];then 
        if [[ "$badInstancesState" != "$terminatedState" ]];then 
            echo "Bad instances are yet to be terminated. Please Wait."
            sleep 1
            getBadInstancesStates
            waitForBadInstancesTermination
        else
            echo "Bad instances have been terminated."
        fi
    fi
}




getBadSubnets () {
    badSubnetsArray=($(aws ec2 describe-subnets $profile $region  \
    --output text --filters Name=tag:Name,Values=$subnetName --query 'Subnets[].SubnetId'))

}




deleteBadSubnets () {

    if ! [ -z "${badSubnetsArray[*]}" ];then 

        for badSubnet in ${badSubnetsArray[*]}; do
            aws ec2 delete-subnet --subnet-id $badSubnet $profile $region 
        done
        echo "Deleted Backlog Subnets: ${badSubnetsArray[*]}"

    else
        echo "There are no Backlog Subnets to delete"

    fi

}


getBadSecurityGroups () {
    badSecurityGroupsArray=($(aws ec2 describe-security-groups $profile $region  \
    --output text --filters Name=tag:Name,Values=$securityGroupName --query 'SecurityGroups[].GroupId'))
}

deleteBadSecurityGroups () {
    if ! [ -z "${badSubnetsArray[*]}" ];then 

        for badSecurityGroup in ${badSecurityGroupsArray[*]}; do
            aws ec2 delete-security-group --group-id $badSecurityGroup $profile $region 
        done
        echo "Deleted Backlog Security Groups: ${badSecurityGroupsArray[*]}"

    else
    echo "There are no Backlog Security Groups to delete"

    fi

}


getBadInternetGWs () {
    badInternetGWIdsArray=($(aws ec2 describe-internet-gateways $profile $region \
    --output text --filters Name=tag:Name,Values=$internetGWName --query 'InternetGateways[].InternetGatewayId'))

}


detachBadInternetGWs () {
    
    if ! [ -z "${badInternetGWIdsArray[*]}" ];then 
    
        for badInternetGWId in ${badInternetGWIdsArray[*]}; do

            attachedBadVPCId=$(aws ec2 describe-internet-gateways  --internet-gateway-ids $badInternetGWId $profile $region  \
            --output text --query 'InternetGateways[].Attachments[].VpcId')

            if ! [ -z "$attachedBadVPCId" ];then 

                aws ec2 detach-internet-gateway --internet-gateway-id $badInternetGWId  --vpc-id $attachedBadVPCId $profile $region 
                echo "Detached internet gateway $badInternetGWId from VPC $attachedBadVPCId"
            else
                echo "$badInternetGWId is already detached"
            fi
            
        done

    else
        echo "There are no backlog internet gateways to detach."
    fi


}

deletebadInternetGWs ()
{
    if ! [ -z "${badInternetGWIdsArray[*]}" ];then

        for badInternetGWId in ${badInternetGWIdsArray[*]}; do
            aws ec2 delete-internet-gateway --internet-gateway-id $badInternetGWId $profile $region 
            echo "Deleted internet gateway $badInternetGWId"
        done
    
    else
        echo "There are no backlog internet gateways to delete."
    fi
}




getBadVPCs () {
    badVPCsArray=($(aws ec2 describe-vpcs $profile $region  --output text --filters Name=tag:Name,Values=Appsec-Scanner-VPC-abc \
    --query 'Vpcs[].VpcId'))

}



deleteBadVPCS () {
    if ! [ -z "${badInternetGWIdsArray[*]}" ];then

        for badVPC in ${badVPCsArray[*]}; do
            aws ec2 delete-vpc --vpc-id "$badVPC" $profile $region 
            echo "Deleted backlog VPC $badVPC."
        done

    else

        echo There are no backlog VPCs to delete.

    fi
}




forceClean () {

    getBadInstances
    terminateBadInstances
    getBadInstancesStates
    waitForBadInstancesTermination
    getBadSubnets
    deleteBadSubnets
    getBadSecurityGroups
    deleteBadSecurityGroups
    getBadInternetGWs
    detachBadInternetGWs
    deletebadInternetGWs
    getBadVPCs
    deleteBadVPCS

}


forceCleanAllRegions () {

    echo ""
    echo "########## FORCE CLEANING ##########"
    regionNumber=1
  
    for regionName in ${regionList[*]};do

        region="--region $regionName"
        echo ""
        echo "########## $regionName region is being cleaned. [$regionNumber / $totalRegions] ##########"
        forceClean
        ((regionNumber++))
        
    done
}




###Final call
prepare () {
    echo ""
    echo "########## STAGE [1/5] - PREPARING PLAYGROUND ##########"
    echo ""
    deleteKey
    getExistingVPCIps
    findCidr
    generateKey
    findMyIp
    createVPC
    createSubnet
    createInternetGW
    attachInternetGW
    getRouteTable
    createRouteToInternetGW
    associatePubSubnetWithRouteTable
    createSecurityGroup
    createIngressRules

}


build () {
    echo ""
    echo "########## STAGE [2/5] - BUILDING INFRASTRUCTURE ##########"
    echo ""
    runInstance
    getVolumes
    createSnapshot
    getSnapshotState
    waitForSnapshotCompletion
    createVolume
    getInstanceState
    waitForRunningScannerInstance 
    attachVolume
    getClonedVolumeState
    waitForClonedVolumeAttachment
    fetchInstanceIp

}


scan () {
    echo ""
    echo "########## STAGE [3/4] - SCANNING ##########"
    sshInstance
    echo ""
}



destroy () {
    echo ""
    echo "########## STAGE [4/5] - DESTROYING INFRASTRUCTURE ##########"
    echo ""
    deleteSnapshot
    terminateInstance
    getInstanceState
    waitForInstanceTermination
    deleteVolume
}







clean () {
    echo ""
    echo "########## STAGE [5/5] - CLEANING ##########"
    echo ""

    deleteSecurityGroup
    disassociatePubSubnetFromRouteTable
    detachInternetGW
    deleteInternetGW
    deleteSubnet
    deleteKey
    deleteVPC
    
}



# if [[ "$1" == "$scanCmd" ]];then

#     prepare && build && scan
#     sleep 1 && destroy && clean

# elif [[ "$1" == "$forceCleanCmd" ]];then

#     #forceClean
#     forceCleanAllRegions

# elif  [ -z "$1" ]; then 

#     echo "Arguments missing . Please use 'scan / forceclean' as arguments."
#     echo "Expamle: ./InstaScanner.sh scan"
#     exit

# else
#      echo "Invalid Arguments provided. Please use 'scan / forceclean' as arguments."
#     echo "Expamle: ./InstaScanner.sh scan"

# fi

createAllRegionsSnapShots
