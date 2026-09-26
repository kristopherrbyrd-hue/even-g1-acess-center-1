import 'package:even_companion/services/action_center_service.dart';
import 'package:flutter/material.dart';

class ActionCenterVirtualHudPage extends StatefulWidget {
  const ActionCenterVirtualHudPage({super.key});
  @override State<ActionCenterVirtualHudPage> createState() => _ActionCenterVirtualHudPageState();
}
class _ActionCenterVirtualHudPageState extends State<ActionCenterVirtualHudPage> {
  final ac = ActionCenterService.get;
  @override void initState(){ super.initState(); ac.virtualReset(); }
  @override void dispose() { ac.leaveVirtualMode(); super.dispose(); }
  Future<void> run(Future<void> Function() f) async { await f(); if(mounted)setState((){}); }
  Widget button(String text, Future<void> Function() f) => Expanded(child: Padding(padding: const EdgeInsets.all(4), child: FilledButton.tonal(onPressed:()=>run(f), child: Text(text,textAlign:TextAlign.center))));
  @override Widget build(BuildContext context){
    return Scaffold(appBar:AppBar(title:const Text('Action Center • Virtual HUD')), body:ListView(padding:const EdgeInsets.all(16),children:[
      const Text('Same Action Center state machine; phone buttons stand in for G1 temple gestures.'), const SizedBox(height:16),
      Container(height:250,padding:const EdgeInsets.all(24),decoration:BoxDecoration(color:Colors.black,borderRadius:BorderRadius.circular(22),border:Border.all(color:Colors.white24,width:2)),child:Center(child:Text(ac.virtualDisplayText,style:const TextStyle(fontFamily:'monospace',fontSize:18,height:1.35),textAlign:TextAlign.left))),
      const SizedBox(height:12), Text('State: ${ac.virtualViewName}   •   Cards: ${ac.cards.length}',textAlign:TextAlign.center), const SizedBox(height:12),
      Row(children:[button('LEFT TAP\nPrevious',ac.virtualLeftTap),button('RIGHT TAP\nNext',ac.virtualRightTap)]),
      Row(children:[button('LEFT HOLD\nEven AI',() async { if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Left hold remains reserved for Even AI.'))); }),button('RIGHT HOLD\nSelect',ac.virtualSelect)]),
      Row(children:[button('BACK',ac.virtualBack),button('RESET',() async=>ac.virtualReset())]),
      const Divider(height:32), const Text('Stress tests',style:TextStyle(fontWeight:FontWeight.bold)),
      Row(children:[button('Incoming notification',() async=>ac.virtualAddIncoming()),button('Remove selected notification',() async=>ac.virtualRemoveActive())]),
      const SizedBox(height:8), const Text('Try this: open Jillian → Reply → move to a quick reply → add an incoming notification → confirm the reply still says JILLIAN. Then remove the selected notification and verify it refuses to switch recipients.'),
    ]));
  }
}
