#!/bin/bash



randomID="abc"
keyName="Appsec-Scanner-Key-Pair-$randomID"
vpcName="Appsec-Scanner-VPC-$randomID"
subnetName="Appsec-Scanner-Pub-Subnet-$randomID"
internetGWName="Appsec-Scanner-InternetGW-$randomID"
routeTableName="Appsec-Scanner-RouteTable-$randomID"
securityGroupName="Appsec-Scanner-SecurityGroup-$randomID"

ad="--profile maerifat"


getExistingVPCs () {
    VPSC=$(aws ec2 describe-vpcs $ad --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' --output text |cut -d "/" -f1|sort -u)
    VPCSarray=("$VPSC")
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
    aws ec2 create-key-pair --key-name $keyName  --query 'KeyMaterial' --output text $ad > /tmp/$keyName.pem
    echo "New SSH key has been created and saved as /tmp/$keyName.pem"
}






findMyIp (){
    myIp=$(curl -s ifconfig.me)
    echo "You public IP address is $myIp"
}


createVPC () {
    newVPCId=$(aws ec2 create-vpc --cidr-block "${availableVPCCIDR}/16" --query 'Vpc.VpcId' --output text $ad)
    echo "New VPC $newVPCId  has been created."
    
    #adding tag
    aws ec2 create-tags --resources "${newVPCId}" --tags "Key=Name,Value=$vpcName" $ad
    echo "Tagged $newVPCId with Name as $vpcName"
    
    #enabling dns hostnames
    aws ec2 modify-vpc-attribute --vpc-id "$newVPCId" --enable-dns-hostnames "{\"Value\":true}" $ad
    echo "Enabled dns host names for $newVPCId ($vpcName)"
    
}

createSubnet () {
    subnetCIDR=$(echo "$availableVPCCIDR"| awk -F "." '{$3=1; print $1 "." $2 "." $3 "." $4}')
    pubSubnetId=$(aws ec2 create-subnet --vpc-id $newVPCId --cidr-block $subnetCIDR/24 \
    --availability-zone ap-south-1a --query 'Subnet.SubnetId' --output text $ad)
    echo "New subnet $subnetCIDR/24 ($pubSubnetId) has been created."
    
    #adding tag
    aws ec2 create-tags --resources $pubSubnetId --tags "Key=Name,Value=$subnetName" $ad
    echo "Tagged $pubSubnetId with Name as $subnetName"
    
    #enabling auto assign public Ip
    aws ec2 modify-subnet-attribute --subnet-id $pubSubnetId --map-public-ip-on-launch $ad
    echo "Enabled auto assignment of public Ip to $pubSubnetId ($subnetName)"
}


createInternetGW () {
    internetGWId=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text $ad)
    echo "Internet Gateway $internetGWId created."
    
    aws ec2 create-tags --resources $internetGWId --tags "Key=Name,Value=myvpc-internet-gateway" $ad
    echo "Tagged $internetGWId with Name as $internetGWName"
    
}



attachInternetGW () {
    aws ec2 attach-internet-gateway --vpc-id $newVPCId --internet-gateway-id $internetGWId $ad
    echo "Attached Internet Gateway ($internetGWId) to VPC ($newVPCId)"
    
}


createRouteTable () {
    routeTableId=$(aws ec2 create-route-table --vpc-id $newVPCId  --query 'RouteTable.RouteTableId' --output text $ad)
    echo "New route table $routeTableId has been created."
    
    #Adding tag
    aws ec2 create-tags --resources $routeTableId --tags "Key=Name,Value=$routeTableName" $ad
    echo "Tagged $routeTableId with Name as $routeTableName"
}


createRouteToInternetGW () {
    ## Create route to Internet Gateway
    aws ec2 create-route \
    --route-table-id $routeTableId \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $internetGWId $ad > /dev/null
    echo "Created route for $routeTableId ($routeTableName) to $internetGWId ($internetGWName)."
}

associatePubSubnetWithRouteTable (){
    ## Associate the public subnet with route table
    routeTableAssociationId=$(aws ec2 associate-route-table  \
    --subnet-id $pubSubnetId \
    --route-table-id $routeTableId \
    --query 'AssociationId'\
    --output text $ad)
    echo "Associated ($routeTableAssociationId) route table ($routeTableId) with the subnet ($pubSubnetId)."
}


createSecurityGroup () {
    
    ## Create a security group
    securityGroupId=$(aws ec2 create-security-group \
    --vpc-id $newVPCId \
    --group-name $securityGroupName \
    --description 'Appsec-Scanner VPC - non default security group' $ad)
    echo "New security group $securityGroupId ($securityGroupName) as been created."
    
    
    ##Getting security group id
    # securityGroupId=$(aws ec2 describe-security-groups $ad \
    # --filters "Name=vpc-id,Values=$newVPCId" \
    # --output json|  jq '.SecurityGroups'|jq '.[] | select(.GroupName == "'$securityGroupName'")'|jq '.GroupId'| tr -d '"') 
    
    # echo "Created security group"
    
    ##Tagging security group
    aws ec2 create-tags \
    --resources $securityGroupId \
    --tags "Key=Name,Value=$securityGroupName" $ad
    echo "Tagged $securityGroupId with Name as $securityGroupName"
    
    
}





createIngressRules () {
    ## Create security group ingress rules
    aws ec2 authorize-security-group-ingress \
    --group-id $securityGroupId \
    --protocol tcp --port 22 --cidr "$myIp/32"  $ad > /dev/null 
    echo "Allowing SSH on port 22 for $securityGroupId ($securityGroupName)."
}

##BUILDING END
####
####




runInstance () {

    intanceId=$(aws ec2 run-instances $ad\
    --image-id ami-04893cdb768d0f9ee \
    --instance-type t2.micro \
    --subnet-id $pubSubnetId \
    --security-group-ids $securityGroupId \
    --associate-public-ip-address \
    --key-name $keyName \
    --output text --query 'Instances[0].InstanceId')

    echo "Ec2 Instance $intanceId has been started."
}







##CLEANSING START
####
####

terminateInstance () {
    aws ec2 terminate-instances --instance-ids $intanceId $ad
    echo "Delete VPC $intanceId"
}

deleteSecurityGroup () {
    ## Delete custom security group
    aws ec2 delete-security-group --group-id $securityGroupId $ad
    echo "Deleted security group $securityGroupId ($securityGroupName)"
}


detachInternetGW (){
    aws ec2 detach-internet-gateway --internet-gateway-id $internetGWId  --vpc-id $newVPCId $ad
    echo "Detached Internet Gateway ($internetGWId) from VPC ($newVPCId)"
}


deleteInternetGW () {
    aws ec2 delete-internet-gateway --internet-gateway-id $internetGWId $ad
    echo "Deleted Internet Gateway $internetGWId"
}



disassociatePubSubnetFromRouteTable () {
    aws ec2 disassociate-route-table --association-id $routeTableAssociationId $ad
    echo "Disassociated route table ($routeTableId) from the subnet ($pubSubnetId)."
}



deleteRouteTable () {
    aws ec2 delete-route-table --route-table-id $routeTableId $ad
    echo "Deleted route table $routeTableId ($routeTableName)"
}




deleteSubnet () {
    aws ec2 delete-subnet --subnet-id "$pubSubnetId" $ad
    echo "Subnet $subnetCIDR/24 ($pubSubnetId) has been deleted."
}

deleteKey () {
    aws ec2 delete-key-pair --key-name $keyName $ad --output json
    rm -f /tmp/$keyName.pem
    echo "SSH key has been deleted and /tmp/$keyName.pem has been removed."
}

deleteVPC () {
    aws ec2 delete-vpc --vpc-id "$newVPCId" $ad
    echo "VPC $newVPCId ($vpcName) has been deleted."
    echo "Scan Completed, Your system is infected."|espeak -p 50 -s 130
}




build () {
    echo ""
    echo "########## STAGE [1/3] - BUILDING ##########"
    echo ""
    getExistingVPCs
    findCidr
    generateKey
    findMyIp
    createVPC
    createSubnet
    createInternetGW
    attachInternetGW
    createRouteTable
    createRouteToInternetGW
    associatePubSubnetWithRouteTable
    createSecurityGroup
    createIngressRules
    runInstance
    
    
}




scan () {
    echo ""
    echo "########## STAGE [2/3] - SCANNING ##########"
    echo ""
}




clean () {
    echo ""
    echo "########## STAGE [3/3] - CLEANING ##########"
    echo ""
    terminateInstance
    sleep 20
    deleteSecurityGroup
    disassociatePubSubnetFromRouteTable
    deleteRouteTable
    detachInternetGW
    deleteInternetGW
    deleteSubnet
    deleteKey
    deleteVPC
    
}

build && scan && clean
