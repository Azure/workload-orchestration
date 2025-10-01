param(
    [Parameter(Mandatory=$true)]
    [string]$InputFilePath
)

function DeleteFiles {
    param (
        [string] $tempFile,
        [string] $publishedFile
    )

    if (Test-Path $tempFile) {
        Remove-Item $tempFile -Force
    }
    if (Test-Path $publishedFile) {
        Remove-Item $publishedFile -Force
    }
}

function RunPublishOrReview {
    param(
    [string]$solutionTemplateName,
    [string]$solutionTemplateVersion,
    [string]$solutionInstanceName,
    [string]$solutionConfiguration,
    [string]$rg,
    [string]$subId,
    [array]$tempFile,
    [string]$dependencies,
    [string] $cmd)

   
    if($cmd -eq "publish") {
     if("" -ne $solutionConfiguration)
        {
            $solutionConfiguration = "@"+$solutionConfiguration
            if("" -eq $solutionInstanceName) {
                
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-configuration ""$solutionConfiguration"" -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-configuration ""$solutionConfiguration"" --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
            }
        
            else {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName --solution-configuration ""$solutionConfiguration"" -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName --solution-configuration ""$solutionConfiguration"" --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
            }
        }
        
        else {
              
            if("" -eq $solutionInstanceName) {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
        }
            else {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
            }
     }
}
else{
      if("" -ne $solutionConfiguration)
        {
            $solutionConfiguration = "@"+$solutionConfiguration
          if("" -eq $solutionInstanceName) {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-configuration ""$solutionConfiguration"" -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-configuration ""$solutionConfiguration"" --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
            }
        
            else {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName --solution-configuration ""$solutionConfiguration"" -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName --solution-configuration ""$solutionConfiguration"" --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
            }
        }
        
        else {
            if("" -eq $solutionInstanceName) {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
        }
            else {
                if("" -eq $dependencies)
                {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName -g $rg --subscription $subId 2>&1)
                }
                else {
                    $result = $(az workload-orchestration solution-template bulk-review -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$tempFile"" --solution-instance-name $solutionInstanceName --dependencies ""$dependencies"" -g $rg --subscription $subId 2>&1)
                }
            }
     }
}
return $result
}

  $publishedFile = [System.IO.Path]::GetTempFileName();
  $tempFile = [System.IO.Path]::GetTempFileName()
try {
    if (-not (Test-Path $InputFilePath)) {
        throw "File not found: $InputFilePath"
    }

    $fileContent = Get-Content $InputFilePath -Raw
    $object = $fileContent | ConvertFrom-Json
    $solutionTemplateName = $object.solutionTemplateName
    $solutionTemplateVersion = $object.solutionTemplateVersion
    $solutionInstanceName = $object.SolutionInstanceName
    $solutionConfiguration = $object.solutionConfiguration
    $dependencies = $object.dependencies
    $rg = $object.resourceGroup
    $subId = $object.subscriptionId
    $targets = $object.targets
    $skipReview = $object.skipReview
    $jsonTargets = ConvertTo-Json $targets
   
    $jsonTargets | Out-File -FilePath $tempFile -Encoding UTF8 -Force
    if($true -eq $skipReview) {
         Write-Output "publishing solution to targets..."
        $result = RunPublishOrReview -solutionTemplateName $solutionTemplateName -solutionTemplateVersion $solutionTemplateVersion -solutionInstanceName $solutionInstanceName -solutionConfiguration $solutionConfiguration -rg $rg -subId $subId -tempFile $tempFile -dependencies $dependencies -cmd "publish"
         if ($LASTEXITCODE -eq 0) {
            $jsonResult = $result | ConvertFrom-Json
            $publishedTargets = $jsonResult.properties.publishedTargets
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($target in $publishedTargets) {
                $obj = @{
                    solutionVersionId = $target.solutionVersionId
                }
                $list.Add($obj)
            }
            $publishedFile = [System.IO.Path]::GetTempFileName()
            $convertedJson = ConvertTo-Json $list
            $convertedJson | Out-File -FilePath $publishedFile -Encoding UTF8 -Force
        
    }
    else {
        $result
        DeleteFiles -tempFile $tempFile -publishedFile $publishedFile
        exit 1;
    }
}
    else {
       Write-Output "reviewing solution to targets..."
         $result = RunPublishOrReview -solutionTemplateName $solutionTemplateName -solutionTemplateVersion $solutionTemplateVersion -solutionInstanceName $solutionInstanceName -solutionConfiguration $solutionConfiguration -rg $rg -subId $subId -tempFile $tempFile -dependencies $dependencies -cmd "review"
         if ($LASTEXITCODE -eq 0) {
        
            Write-Host "Executed review command"
            $jsonResult = $result | ConvertFrom-Json
            $reviewedTargets = $jsonResult.properties.reviewedTargets
            $replace = (New-Guid).ToString() -replace "-", "" 
            $file = $replace+ ".json"
            $converted = ConvertTo-Json $reviewedTargets
            Out-File -FilePath $file -Encoding UTF8 -InputObject $converted
            Write-Output "Review file created at: $file"
            Read-Host -Prompt "Press Enter to continue with publish"
            Write-Host $converted
            $converted | Out-File -FilePath $tempFile -Encoding UTF8 -Force
            Write-Output "publishing solution to targets..."

            $result = $(az workload-orchestration solution-template bulk-publish -n $solutionTemplateName -v $solutionTemplateVersion --targets ""@$tempFile"" -g $rg --subscription $subId 2>&1)
             if ($LASTEXITCODE -eq 0) {
                Write-Host "Publish command executed successfully"
                $jsonResult = $result | ConvertFrom-Json
            
                $publishedTargets = $jsonResult.properties.publishedTargets
                $list = [System.Collections.Generic.List[object]]::new()
                foreach ($target in $publishedTargets) {
                $obj = @{
                    solutionVersionId = $target.solutionVersionId
                }
                $list.Add($obj)
             }
          
            $convertedJson = ConvertTo-Json $list
            $convertedJson | Out-File -FilePath $publishedFile -Encoding UTF8 -Force
            } 
            else {
                    Write-Host "Publish command failed"
                    $result
                    exit 1;
            }
        }
    else {
       $result
       DeleteFiles -tempFile $tempFile -publishedFile $publishedFile
       exit 1;
    }
}
    Write-Output "deploying solution to targets..."
    
    $result = $(az workload-orchestration solution-template bulk-deploy -n $solutionTemplateName -v $solutionTemplateVersion --targets ""$publishedFile"" -g $rg --subscription $subId 2>&1)
    
    if ($LASTEXITCODE -eq 0) {
        $result
    }
    else {
        $result
    }
}
catch {
    Write-Host "Full Exception Details: $($_ | Out-String)"
    Write-Error "Error occurred: $($_Exception.Message)"
    DeleteFiles -tempFile $tempFile -publishedFile $publishedFile
    exit 1  
}


