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
tempRegion="ap-south-1"
username="ec2-user"
profileName="maerifat"
profile="--profile $profileName"


getReglionList () {
    regionList=($(aws ec2 describe-regions $profile --output text --query 'Regions[].RegionName[]'))
}

getExistingVPCs () {

    for tempRegion in ${regionList[*]}; do 
    aws ec2 describe-vpcs $profile --output text --query 'Vpcs[].VpcId'
    done
}

getExistingVPCIps () {
    VPCS=$(aws ec2 describe-vpcs $profile --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' --output text |cut -d "/" -f1|sort -u)
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
    aws ec2 create-key-pair --key-name $keyName  --query 'KeyMaterial' --output text $profile > /tmp/$keyName.pem
    echo "New SSH key has been created and saved as /tmp/$keyName.pem"
}






findMyIp (){
    myIp=$(curl -s ifconfig.me)
    echo "You public IP address is $myIp"
}


createVPC () {
    newVPCId=$(aws ec2 create-vpc --cidr-block "${availableVPCCIDR}/16" --query 'Vpc.VpcId' --output text $profile)
    echo "New VPC $newVPCId  has been created."
    
    #adding tag
    aws ec2 create-tags --resources "${newVPCId}" --tags "Key=Name,Value=$vpcName" $profile
    echo "Tagged $newVPCId with Name as $vpcName"
    
    #enabling dns hostnames
    aws ec2 modify-vpc-attribute --vpc-id "$newVPCId" --enable-dns-hostnames "{\"Value\":true}" $profile
    echo "Enabled dns host names for $newVPCId ($vpcName)"
    
}


getRouteTable () {
    routeTableId=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$newVPCId --output text $profile\
    --query 'RouteTables[].Associations[?Main==`true`][].RouteTableId')

    echo "Route Table of $newVPCId is $routeTableId"
        #Adding tag
    aws ec2 create-tags --resources $routeTableId --tags "Key=Name,Value=$routeTableName" $profile
    echo "Tagged $routeTableId with Name as $routeTableName"
}


createSubnet () {
    subnetCIDR=$(echo "$availableVPCCIDR"| awk -F "." '{$3=1; print $1 "." $2 "." $3 "." $4}')
    pubSubnetId=$(aws ec2 create-subnet --vpc-id $newVPCId --cidr-block $subnetCIDR/24 \
    --availability-zone ap-south-1a --query 'Subnet.SubnetId' --output text $profile)
    echo "New subnet $subnetCIDR/24 ($pubSubnetId) has been created."
    
    #adding tag
    aws ec2 create-tags --resources $pubSubnetId --tags "Key=Name,Value=$subnetName" $profile
    echo "Tagged $pubSubnetId with Name as $subnetName"
    
    #enabling auto assign public Ip
    aws ec2 modify-subnet-attribute --subnet-id $pubSubnetId --map-public-ip-on-launch $profile
    echo "Enabled auto assignment of public Ip to $pubSubnetId ($subnetName)"
}


createInternetGW () {
    internetGWId=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text $profile)
    echo "Internet Gateway $internetGWId created."
    
    aws ec2 create-tags --resources $internetGWId --tags "Key=Name,Value=$internetGWName" $profile
    echo "Tagged $internetGWId with Name as $internetGWName"
    
}



attachInternetGW () {
    aws ec2 attach-internet-gateway --vpc-id $newVPCId --internet-gateway-id $internetGWId $profile
    echo "Attached Internet Gateway $internetGWId to VPC $newVPCId"
    
}


# createRouteTable () {
#     routeTableId=$(aws ec2 create-route-table --vpc-id $newVPCId  --query 'RouteTable.RouteTableId' --output text $profile)
#     echo "New route table $routeTableId has been created."
    
#     #Adding tag
#     aws ec2 create-tags --resources $routeTableId --tags "Key=Name,Value=$routeTableName" $profile
#     echo "Tagged $routeTableId with Name as $routeTableName"
# }


createRouteToInternetGW () {
    ## Create route to Internet Gateway
    aws ec2 create-route \
    --route-table-id $routeTableId \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $internetGWId $profile > /dev/null
    echo "Created route for $routeTableId ($routeTableName) to $internetGWId ($internetGWName)."
}

associatePubSubnetWithRouteTable (){
    ## Associate the public subnet with route table
    routeTableAssociationId=$(aws ec2 associate-route-table  \
    --subnet-id $pubSubnetId \
    --route-table-id $routeTableId \
    --query 'AssociationId'\
    --output text $profile)
    echo "Associated ($routeTableAssociationId) route table $routeTableId with the subnet $pubSubnetId."
}


createSecurityGroup () {
    
    ## Create a security group
    securityGroupId=$(aws ec2 create-security-group \
    --vpc-id $newVPCId \
    --group-name $securityGroupName \
    --description 'Appsec-Scanner VPC - non default security group' $profile)
    echo "New security group $securityGroupId ($securityGroupName) as been created."
    
    
    ##Getting security group id
    # securityGroupId=$(aws ec2 describe-security-groups $profile \
    # --filters "Name=vpc-id,Values=$newVPCId" \
    # --output json|  jq '.SecurityGroups'|jq '.[] | select(.GroupName == "'$securityGroupName'")'|jq '.GroupId'| tr -d '"') 
    
    # echo "Created security group"
    
    ##Tagging security group
    aws ec2 create-tags \
    --resources $securityGroupId \
    --tags "Key=Name,Value=$securityGroupName" $profile
    echo "Tagged $securityGroupId with Name as $securityGroupName"
    
    
}


createIngressRules () {
    ## Create security group ingress rules
    aws ec2 authorize-security-group-ingress \
    --group-id $securityGroupId \
    --protocol tcp --port 22 --cidr "$myIp/32"  $profile > /dev/null 
    echo "Allowing SSH from $myIp on port 22 for $securityGroupId ($securityGroupName)."
}

##BUILDING END
####
####




runInstance () {

    scannerInstanceId=$(aws ec2 run-instances $profile\
    --image-id ami-04893cdb768d0f9ee \
   --instance-type t2.micro \
    --subnet-id $pubSubnetId \
    --security-group-ids $securityGroupId \
    --associate-public-ip-address \
    --key-name $keyName \
    --output text --query 'Instances[0].InstanceId')

    echo "Ec2 Instance $scannerInstanceId has been started."

    aws ec2 create-tags --resources $scannerInstanceId --tags "Key=Name,Value=$scannerInstanceName" $profile > /dev/null
}


##BUILDING INFRASTRUCTURE
####
####






#for tempRegion in  ${regionList[*]};do  \

getVolumeIds () {
volumeIdsArray=($(aws ec2 describe-volumes $profile --region $tempRegion  \
--output text --query 'Volumes[].Attachments[].VolumeId' --output text))

echo "Collected VolumeIds on region $tempRegion"
echo ${volumeIdsArray[*]}
}


createSnapshot () {
    snapshotId=$(aws ec2 create-snapshot $profile --volume-id ${volumeIdsArray[0]}  \
    --description "This snapshot has been created by appsec scanner." --query 'SnapshotId' --output text)
     echo "Created snapshot $snapshotId of volume ${volumeIdsArray[0]} "
     
    aws ec2 create-tags --resources $snapshotId --tags "Key=Name,Value=$snapshotName" $profile > /dev/null
    echo "Tagged $snapshotId with Name as $snapshotName"
   
}


getSnapshotState () {
    snapshotState=$(aws ec2 describe-snapshots --snapshot-id $snapshotId  $profile --output text \
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
    clonedVolumeId=$(aws ec2 create-volume $profile \
    --volume-type io1 \
    --iops 1000 \
    --snapshot-id $snapshotId \
    --availability-zone ap-south-1a --output text --query 'VolumeId')

    echo "Created new volume $clonedVolumeId from $snapshotId"

    aws ec2 create-tags --resources $clonedVolumeId --tags "Key=Name,Value=$clonedVolumeName" $profile > /dev/null
    echo "Tagged $clonedVolumeId with Name as $clonedVolumeName"
    
}




attachVolume (){
    aws ec2 attach-volume $profile\
    --device /dev/sdf \
    --instance-id $scannerInstanceId \
    --volume-id $clonedVolumeId

    
    echo "Initiated attachment of $clonedVolumeId with $scannerInstanceId"
}


getClonedVolumeState () {
    clonedVolumeState=$(aws ec2 describe-volumes --volume-id $clonedVolumeId $profile \
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
    instanceIpAddress=$(aws ec2 describe-instances --instance-id  $scannerInstanceId $profile\
    --output text  --query 'Reservations[].Instances[].PublicIpAddress')
    echo "Public Ip address of $scannerInstanceId is $instanceIpAddress"
}


sshInstance () {

    echo "Initiated ssh connection"
    chmod 600 $keyLocation

    echo "Try manual connection: ssh -i $keyLocation -o StrictHostKeyChecking=no $username@$instanceIpAddress"

    sshCommands="lsblk;pwd;whoami;"

    ssh -i $keyLocation -o StrictHostKeyChecking=no $username@$instanceIpAddress "$sshCommands"

    
    
}





deleteSnapshot () {
    aws ec2 delete-snapshot $profile --snapshot-id $snapshotId 
    echo "Delete snapshot $snapshotId ($snapshotName)"
}


deleteVolume () {
    aws ec2 delete-volume --volume-id $clonedVolumeId $profile > /dev/null
    echo "Deleted new volume $clonedVolumeId ($clonedVolumeName)"
}
##CLEANSING START
####
####

terminateInstance () {
    aws ec2 terminate-instances --instance-ids $scannerInstanceId $profile > /dev/null
    echo "Initiated termination of Ec2 instance $scannerInstanceId ($scannerInstanceName)."
}



getInstanceState () {
    instanceState=$(aws ec2 describe-instances  $profile --output json \
    --query 'Reservations[].Instances[]'| jq '.[]| select(.InstanceId == "'$scannerInstanceId'")'| jq '.State.Name'|tr -d '"')

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
    aws ec2 delete-security-group --group-id $securityGroupId $profile
    echo "Deleted security group $securityGroupId ($securityGroupName)"
}


detachInternetGW (){
    aws ec2 detach-internet-gateway --internet-gateway-id $internetGWId  --vpc-id $newVPCId $profile
    echo "Detached Internet Gateway $internetGWId from VPC $newVPCId"
}


deleteInternetGW () {
    aws ec2 delete-internet-gateway --internet-gateway-id $internetGWId $profile
    echo "Deleted Internet Gateway $internetGWId ($internetGWName)"
}



disassociatePubSubnetFromRouteTable () {
    aws ec2 disassociate-route-table --association-id $routeTableAssociationId $profile
    echo "Disassociated route table ($routeTableId) from the subnet ($pubSubnetId)."
}



# deleteRouteTable () {
#     aws ec2 delete-route-table --route-table-id $routeTableId $profile
#     echo "Deleted route table $routeTableId ($routeTableName)"
# }


deleteSubnet () {
    aws ec2 delete-subnet --subnet-id "$pubSubnetId" $profile
    echo "Subnet $subnetCIDR/24 ($pubSubnetId) has been deleted."
}

deleteKey () {
    aws ec2 delete-key-pair --key-name $keyName $profile --output json
    rm -f /tmp/$keyName.pem
    echo "SSH key has been deleted and /tmp/$keyName.pem has been removed."
}

deleteVPC () {
    aws ec2 delete-vpc --vpc-id "$newVPCId" $profile
    echo "VPC $newVPCId ($vpcName) has been deleted."
    echo "Scan Completed, Your system is infected."|espeak -p 50 -s 130
    echo ""
}



getBadInstances () {
    
    badInstancesArray=($(aws ec2 describe-instances $profile --output text --filters Name=tag:Name,Values=$scannerInstanceName \
    --query 'Reservations[].Instances[].InstanceId'))

    echo "The backlog instances will be deleted: " "${badInstancesArray[*]}"
}



terminateBadInstances () {

    for badInstance in ${badInstancesArray[*]};do

    aws ec2 terminate-instances --instance-ids $badInstance $profile 
    echo "Initiated termination of backlog instances"
    done
}



getBadInstancesStates () {

    badInstancesState=$(aws ec2 describe-instances $profile --output text --filters Name=tag:Name,Values=$scannerInstanceName \
    --query 'Reservations[].Instances[].State.Name'|xargs| tr " " "\n"|sort -u)
}




waitForBadInstancesTermination () {
    if [[ "$badInstancesState" != "$terminatedState" ]];then 
        echo "Bad instances are yet to be terminated. Please Wait."
        sleep 1
        getBadInstancesStates
        waitForBadInstancesTermination
    else
        echo "Bad instances have been terminated."
    fi
}


getBadVPCs () {
    badVPCsArray=($(aws ec2 describe-vpcs $profile --output text --filters Name=tag:Name,Values=Appsec-Scanner-VPC-abc \
    --query 'Vpcs[].VpcId'))
    echo "These backlog VPCs will be deleted: " "${badVPCsArray[*]}"
}

deleteBadVPCS () {
    for badVPC in ${badVPCsArray[*]}; do
     aws ec2 delete-vpc --vpc-id "$badVPC" $profile
     echo "All backlog VPCs have been deleted successfully."

     done
}




forceClean () {
    getBadInstances
    terminateBadInstances
    getBadInstancesStates
    waitForBadInstancesTermination
    getBadVPCs
    deleteBadVPCS



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
    getVolumeIds
    createSnapshot
    getSnapshotState
    waitForSnapshotCompletion
    createVolume
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




prepare && build && scan
#sleep 1 && destroy && clean
#forceClean
