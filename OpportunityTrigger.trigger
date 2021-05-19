/*------------------------------------------------------------------------------------
Author:       
Company:      Arxxus Technology Partners 
Description:  This trigger routes all opportunity related triggers to the
			   OpportunityTriggerHandler class using the TriggerEventRouter
History
Date           Author             Comments
--------------------------------------------------------------------------------------
14-03-2018            Initial Release
------------------------------------------------------------------------------------*/
trigger OpportunityTrigger on Opportunity (before insert,before update,before delete,after insert, after update,
                                          after delete, after undelete) {
			TriggerEventRouter.route(new OpportunityTriggerHandler());
}